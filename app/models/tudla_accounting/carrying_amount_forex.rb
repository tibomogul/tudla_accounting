# frozen_string_literal: true

module TudlaAccounting
  class CarryingAmountForex < ApplicationRecord
    belongs_to :carrying_amount, class_name: "TudlaAccounting::CarryingAmount"

    monetize :other_currency_amount_cents, with_model_currency: :other_currency
  end
end
