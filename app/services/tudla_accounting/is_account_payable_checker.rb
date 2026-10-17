# frozen_string_literal: true

module TudlaAccounting
  # Checks whether a Detail posts to its organization's accounts payable account (the
  # one marked payable, Account#role) or any account beneath it. The role is read from the
  # database, not the loaded account: posting loads its accounts before taking the posting
  # lock, and a role assigned meanwhile (AccountRoleAssigner, under that lock) must count.
  #
  #   IsAccountPayableChecker.call(detail: detail)
  #
  # To check several lines, look the role up once (CarryingAmountProcessor, per entry):
  #
  #   checker = IsAccountPayableChecker.new(organization)
  #   entry.details.find { |detail| checker.call(detail: detail) }
  class IsAccountPayableChecker
    def self.call(detail:)
      account = detail&.account
      account.present? && new(account.organization).call(detail: detail)
    end

    def initialize(organization)
      @account_id = Account.where(organization: organization).role_payable.pick(:id)
    end

    def call(detail:)
      account = detail&.account
      @account_id.present? && account.present? && account.path_ids.include?(@account_id)
    end
  end
end
