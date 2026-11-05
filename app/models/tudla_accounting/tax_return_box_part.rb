# frozen_string_literal: true

module TudlaAccounting
  # One thing a tax return box adds (sign 1) or subtracts (-1): a tax code's net amount,
  # tax or the two together (source tax_code_base, tax_code_tax, tax_code_gross), as the
  # tax summary has them; an account's movement on its natural side (account); what was
  # credited to an account, whatever was paid out of it (account_credits); or an earlier
  # box's figure (box).
  class TaxReturnBoxPart < ApplicationRecord
    SOURCES = { "tax_code_base" => "Net amount taxed under", "tax_code_tax" => "Tax under", "tax_code_gross" => "Gross amount taxed under",
                "account" => "Movement in the account", "account_credits" => "Credits to the account", "box" => "The box" }.freeze

    belongs_to :box, class_name: "TudlaAccounting::TaxReturnBox", inverse_of: :parts
    belongs_to :tax_code, class_name: "TudlaAccounting::TaxCode", optional: true
    belongs_to :account, class_name: "TudlaAccounting::Account", optional: true
    belongs_to :from_box, class_name: "TudlaAccounting::TaxReturnBox", optional: true, inverse_of: :uses

    before_validation :keep_only_its_source

    validates :source, inclusion: { in: SOURCES.keys }
    validates :sign, inclusion: { in: [ 1, -1 ] }
    validates :tax_code, presence: true, if: :tax_code_source?
    validates :account, presence: true, if: :account_source?
    validates :from_box, presence: true, if: -> { source == "box" }

    def tax_code_source?
      source.to_s.start_with?("tax_code_")
    end

    def account_source?
      source.to_s.start_with?("account")
    end

    # "less Tax under GST", "Movement in the account 6040 - Wages".
    def description
      what = case source
      when "account", "account_credits" then account.code_with_name
      when "box" then from_box.label
      else tax_code.code
      end
      "#{'less ' if sign == -1}#{SOURCES.fetch(source)} #{what}"
    end

    private

    # The form sends every field; only the source's own is kept.
    def keep_only_its_source
      self.tax_code = nil unless tax_code_source?
      self.account = nil unless account_source?
      self.from_box = nil unless source == "box"
    end
  end
end
