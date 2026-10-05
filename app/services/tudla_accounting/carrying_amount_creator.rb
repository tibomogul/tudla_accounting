# frozen_string_literal: true

module TudlaAccounting
  # Imports one receivable or payable that was still open when moving from another
  # system, so the aging report and later payments work:
  #
  #   creator = CarryingAmountCreator.new(organization: org, date_prior: Date.new(2025, 12, 31),
  #                                       sales_account_code: "4000", purchase_account_code: "5000",
  #                                       source: ->(row) { Invoice.create!(number: row[:particulars]) })
  #   creator.call(particulars: "Invoice 1001", amount: "1000.00", type: "receivable", due_date: "2026-01-15")
  #
  # It creates an entry dated date_prior (receivable/payable against sales/purchases) that
  # is marked posted but does not change balances: the opening balances already include
  # these amounts. It then opens the carrying amount, with its due date and related party.
  #
  # A row in another currency (other_currency, other_currency_amount, transaction_rate,
  # conversion_date) goes to a sub-account in that currency under the receivable or payable
  # account, e.g. "1100-EUR", created if needed; `amount` is always in the organization's
  # currency. The receivable/payable accounts come from the receivable_account_code and
  # payable_account_code settings. `source` optionally turns the row into a host record
  # for the entry's source (and the related_party_method setting).
  class CarryingAmountCreator
    TYPES = %w[receivable payable].freeze

    attr_reader :organization, :date_prior

    def initialize(organization:, date_prior:, sales_account_code:, purchase_account_code:, source: nil)
      @organization = organization
      @date_prior = date_prior.in_time_zone(TudlaAccounting.configuration.time_zone)
      @offset_codes = { "receivable" => sales_account_code, "payable" => purchase_account_code }
      @source = source
      check_settings!
    end

    # Returns the carrying amount.
    def call(row)
      row = row.to_h.with_indifferent_access
      type = row[:type].to_s.strip
      raise ArgumentError, "Unknown type #{row[:type].inspect} for #{row[:particulars]}; use receivable or payable" unless TYPES.include?(type)

      ActiveRecord::Base.transaction do
        source = @source&.call(row)
        account = account_for(type, other_currency(row))
        entry = TudlaAccounting::Entry.create_from_ruby_hash(entry_hash(row, type, account, source))
        open_carrying_amount(row, type, entry.details.find { |detail| detail.account_id == account.id }, source)
      end
    end

    private

    def check_settings!
      %i[receivable_account_code payable_account_code].each do |setting|
        raise ArgumentError, "TudlaAccounting.configuration.#{setting} is not set" if TudlaAccounting.configuration.public_send(setting).blank?
      end
      @offset_codes.each { |type, code| raise ArgumentError, "No #{type == 'receivable' ? 'sales' : 'purchase'} account code given" if code.blank? }
    end

    def entry_hash(row, type, account, source)
      amount = "#{currency} #{money(row[:amount], currency, row)}"
      line = { account_code: account.code, amount: amount }
      line[:fx] = { other_currency_amount: "#{other_currency(row)} #{money(row[:other_currency_amount], other_currency(row), row)}",
                    fx_rate: row[:transaction_rate].to_s } if other_currency(row)

      {
        organization_type: organization.class.name, organization_id: organization.id,
        source_type: source&.class&.name, source_id: source&.id,
        particulars: row[:particulars].to_s,
        transacted_at: date_prior.iso8601, posted_at: date_prior.iso8601,
        details: [ line, { account_code: @offset_codes.fetch(type), amount: amount } ]
      }
    end

    def open_carrying_amount(row, type, detail, source)
      carrying_amount = TudlaAccounting::CarryingAmount.create!(
        detail: detail, amount_cents: detail.amount_cents, carrying_amount_type: type,
        due_date: date(row[:due_date]),
        related_party: related_party(source)
      )
      if other_currency(row)
        carrying_amount.create_forex!(
          other_currency: other_currency(row),
          other_currency_amount_cents: Money.from_amount(decimal(row[:other_currency_amount], row), other_currency(row)).cents,
          transaction_rate: decimal(row[:transaction_rate], row),
          conversion_date: date(row[:conversion_date]) || date_prior.to_date
        )
      end
      carrying_amount
    end

    # The receivable or payable account, or its sub-account in a foreign currency.
    def account_for(type, foreign_currency)
      code = TudlaAccounting.configuration.public_send("#{type}_account_code")
      base = TudlaAccounting::Account.find_by(organization: organization, code: code)
      raise ArgumentError, "#{type.capitalize} account #{code} not found" unless base
      return base.children.find_by(currency: currency) || base unless foreign_currency

      base.children.find_by(currency: foreign_currency) ||
        TudlaAccounting::Account.create!(organization: organization, parent: base, code: "#{base.code}-#{foreign_currency}",
                                         name: "#{base.name} - #{foreign_currency}", category: base.category,
                                         currency: foreign_currency, contra_account_id: base.contra_account_id)
    end

    def related_party(source)
      method = TudlaAccounting.configuration.related_party_method
      party = source.public_send(method) if source && method && source.respond_to?(method)
      party || organization
    end

    def other_currency(row)
      value = row[:other_currency].to_s.strip.upcase
      value.presence unless value == currency
    end

    def currency
      organization.currency
    end

    def money(value, currency, row)
      Money.from_amount(decimal(value, row), currency).to_s
    end

    def decimal(value, row)
      BigDecimal(value.to_s.strip.delete(","))
    rescue ArgumentError
      raise ArgumentError, "#{value.inspect} is not a number (#{row[:particulars]})"
    end

    def date(value)
      Date.iso8601(value.to_s) if value.present?
    end
  end
end
