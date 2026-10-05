# frozen_string_literal: true

module TudlaAccounting
  # Checks whether a Detail posts to an accounts receivable account, i.e. one whose code starts with "11".
  class IsAccountReceivableChecker
    def self.call(detail:)
      new(detail: detail).call
    end

    def initialize(detail:)
      @detail = detail
    end

    def call
      return false unless @detail&.account&.code

      @detail.account.code.start_with?("11")
    end
  end
end
