# frozen_string_literal: true

module TudlaAccounting
  # Checks whether a Detail posts to its organization's accounts payable account (the
  # one marked payable, Account#role) or any account beneath it. The role is read from the
  # database, not the loaded account: posting loads its accounts before taking the posting
  # lock, and a role assigned meanwhile (AccountRoleAssigner, under that lock) must count.
  class IsAccountPayableChecker
    def self.call(detail:)
      new(detail: detail).call
    end

    def initialize(detail:)
      @detail = detail
    end

    def call
      account = @detail&.account
      return false if account.nil?

      Account.where(id: account.path_ids).role_payable.exists?
    end
  end
end
