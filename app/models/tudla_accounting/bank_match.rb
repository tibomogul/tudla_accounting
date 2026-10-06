# frozen_string_literal: true

module TudlaAccounting
  # A posted ledger line on a bank account, matched to the statement line it appears as.
  # Each ledger line matches one statement line at most.
  class BankMatch < ApplicationRecord
    belongs_to :organization, polymorphic: true
    belongs_to :bank_statement_line, class_name: "TudlaAccounting::BankStatementLine"
    belongs_to :detail, class_name: "TudlaAccounting::Detail"
  end
end
