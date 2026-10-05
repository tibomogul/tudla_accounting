# frozen_string_literal: true

module TudlaAccounting
  # Returns the carrying amount role (:receivable, :payable, :receipt or :disbursement)
  # configured for an Entry's source_type, or nil when it plays none.
  class CarryingAmountRole
    def self.call(entry:)
      new(entry: entry).call
    end

    def initialize(entry:)
      @entry = entry
    end

    def call
      TudlaAccounting.configuration.carrying_amount_sources[@entry&.source_type]
    end
  end
end
