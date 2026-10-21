# frozen_string_literal: true

module TudlaAccounting
  # A budget's amount for an account in a month, on the account's own side. Lines are
  # written through Budget#set_amounts!, which checks them.
  class BudgetLine < ApplicationRecord
    belongs_to :budget, class_name: "TudlaAccounting::Budget"
    belongs_to :account, class_name: "TudlaAccounting::Account"
    belongs_to :period, class_name: "TudlaAccounting::Period"
  end
end
