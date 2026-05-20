# frozen_string_literal: true

module TudlaAccounting
  class CarryingAmount < ApplicationRecord
    belongs_to :detail, class_name: "TudlaAccounting::Detail"
    belongs_to :related_party, polymorphic: true
    has_one :forex, class_name: "TudlaAccounting::CarryingAmountForex", dependent: :destroy

    enum :carrying_amount_type, {
      receivable: 0,
      payable: 1
    }

    def amount
      Money.new(amount_cents, TudlaAccounting.configuration.base_currency)
    end
  end
end
