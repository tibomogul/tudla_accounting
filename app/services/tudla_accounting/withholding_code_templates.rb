# frozen_string_literal: true

module TudlaAccounting
  # Ready-made lists of withholding codes, which an organization adds to its own and can
  # then change. The rates are as published when the list was written, so check them against
  # the tax authority's current ones before relying on them.
  module WithholdingCodeTemplates
    # BIR Form 1601-EQ, January 2019 (ENCS), its schedule of ATCs, with the top withholding
    # agents' rates as RR 24-2025 leaves them. An individual's lower rate depends on a sworn
    # declaration of gross receipts (RR 11-2018). Each is [individual's code and rate,
    # corporation's code and rate]; the codes for less common payments, and the 1/2% ones
    # for certain manufacturers and importers (RMC 36-2026), are left to be added by hand.
    PHILIPPINE_PAYMENTS = {
      "Professionals" => { lower: [ "WI010", "0.05", "WC010", "0.10" ], higher: [ "WI011", "0.10", "WC011", "0.15" ] },
      "Management and technical consultants" => { lower: [ "WI050", "0.05", "WC050", "0.10" ], higher: [ "WI051", "0.10", "WC051", "0.15" ] },
      "Business and bookkeeping agents" => { lower: [ "WI060", "0.05", "WC060", "0.10" ], higher: [ "WI061", "0.10", "WC061", "0.15" ] },
      "Rentals" => { flat: [ "WI100", "0.05", "WC100", "0.05" ] },
      "Certain contractors" => { flat: [ "WI120", "0.02", "WC120", "0.02" ] },
      "Top withholding agents: goods" => { flat: [ "WI158", "0.01", "WC158", "0.01" ] },
      "Top withholding agents: services" => { flat: [ "WI160", "0.02", "WC160", "0.02" ] }
    }.freeze
    BRACKETS = {
      lower: { individual: "income up to ₱3M", corporate: "income up to ₱720,000" },
      higher: { individual: "income over ₱3M or VAT-registered", corporate: "income over ₱720,000" },
      flat: { individual: nil, corporate: nil }
    }.freeze

    TEMPLATES = {
      "ph_expanded" => {
        country: "PH",
        title: "Philippines: expanded withholding tax, common payments (BIR Form 1601-EQ, January 2019)",
        codes: PHILIPPINE_PAYMENTS.flat_map do |payment, brackets|
          brackets.flat_map do |bracket, (individual, individual_rate, corporate, corporate_rate)|
            [ [ individual, individual_rate, :individual ], [ corporate, corporate_rate, :corporate ] ].map do |code, rate, payee|
              { code: code, name: [ "#{payment} (#{payee})", BRACKETS.dig(bracket, payee) ].compact.join(", "), rate: BigDecimal(rate) }
            end
          end
        end
      },
      # Withheld from a payment to a supplier who hasn't quoted an ABN, at the top marginal
      # rate (47% since 1 July 2017, as the ATO's pages give it).
      "au_no_abn" => {
        country: "AU",
        title: "Australia: PAYG withholding where no ABN is quoted",
        codes: [ { code: "NOABN", name: "No ABN quoted", rate: BigDecimal("0.47"), withheld_on: "payment", exempt_up_to_cents: 75_00 } ]
      }
    }.freeze

    module_function

    # [[title, key]] for a select: the organization's country's (Jurisdictions), or all.
    def choices(organization = nil)
      (organization ? Jurisdictions.templates_for(organization, TEMPLATES) : TEMPLATES).map { |key, template| [ template[:title], key ] }
    end

    # Adds the template's codes the organization doesn't have yet, all or none, each with
    # the accounts given (one or both; a code withheld on payment takes only the payable
    # one); the number added. ArgumentError when they won't do.
    def add!(organization, key, payable_account: nil, creditable_account: nil)
      template = TEMPLATES.fetch(key.to_s) { raise ArgumentError, "Unknown withholding code template #{key.inspect}; expected one of #{TEMPLATES.keys.join(', ')}" }
      existing = WithholdingCode.where(organization: organization).pluck(:code).to_set
      missing = template[:codes].reject { |code| existing.include?(code[:code]) }
      WithholdingCode.transaction do
        missing.each do |code|
          WithholdingCode.create!(organization: organization, payable_account: payable_account, creditable_account: (creditable_account unless code[:withheld_on] == "payment"), **code)
        end
      end
      missing.size
    rescue ActiveRecord::RecordInvalid => e
      raise ArgumentError, e.record.errors.full_messages.to_sentence
    end
  end
end
