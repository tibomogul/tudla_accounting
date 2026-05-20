# frozen_string_literal: true

module TudlaAccounting
  class ForeignExchange < ApplicationRecord
    belongs_to :detail, class_name: "TudlaAccounting::Detail"

    monetize :other_currency_cents, as: :foreign_amount, with_model_currency: :other_currency
  end
end
