# frozen_string_literal: true

module TudlaAccounting
  # Checks whether a Detail posts to the configured accounts payable account
  # (TudlaAccounting.configuration.payable_account_code) or any account beneath it.
  class IsAccountPayableChecker
    def self.call(detail:)
      new(detail: detail).call
    end

    def initialize(detail:)
      @detail = detail
    end

    def call
      code = TudlaAccounting.configuration.payable_account_code
      account = @detail&.account
      return false if code.blank? || account.nil?

      account.code == code || account.ancestors.exists?(code: code)
    end
  end
end
