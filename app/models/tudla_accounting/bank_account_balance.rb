# frozen_string_literal: true

module TudlaAccounting
  class BankAccountBalance < ApplicationRecord
    belongs_to :account, class_name: "TudlaAccounting::Account"

    monetize :balance_cents, with_model_currency: :currency
  end
end
