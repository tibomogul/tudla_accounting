# frozen_string_literal: true

module TudlaAccounting
  # How an organization is registered for tax, from the tax_registration setting: what its
  # number is called and the number, the name of the tax, and the title an invoice takes.
  # Printed documents use these. check, if given, says whether a number is well formed:
  # it can't say the number is registered, and a foreign contact's number won't pass, so a
  # failure is only ever a warning.
  #
  #   TaxRegistration.australia("51 824 753 556")
  #   TaxRegistration.new(label: "VAT reg no.", number: "123", tax_name: "VAT", invoice_title: "VAT invoice")
  class TaxRegistration < Data.define(:label, :number, :tax_name, :invoice_title, :check)
    # The Australian Business Register's weights, for its "Format of the ABN".
    ABN_WEIGHTS = [ 10, 1, 3, 5, 7, 9, 11, 13, 15, 17, 19 ].freeze

    def self.australia(abn)
      new(label: "ABN", number: abn, tax_name: "GST", invoice_title: "Tax invoice", check: method(:abn?))
    end

    # Whether a number has an ABN's 11 digits and its check digits add up.
    def self.abn?(text)
      digits = text.to_s.gsub(/[\s-]/, "")
      return false unless digits.match?(/\A\d{11}\z/)

      first, *rest = digits.chars.map(&:to_i)
      [ first - 1, *rest ].zip(ABN_WEIGHTS).sum { |digit, weight| digit * weight }.modulo(89).zero?
    end

    def initialize(label:, number: nil, tax_name: "Tax", invoice_title: nil, check: nil)
      super(label: label, number: number.to_s.strip.presence, tax_name: tax_name, invoice_title: invoice_title, check: check)
    end

    # Whether the number given doesn't pass the check; nothing to check is no failure.
    def fails_check?(text) = text.present? && check.present? && !check.call(text)

    # What a contact's number is called: the label only when it has passed the check.
    def contact_label(text) = check.present? && !fails_check?(text) ? label : "Tax number"
  end
end
