# frozen_string_literal: true

module TudlaAccounting
  # Returns the carrying amount role (:receivable, :payable, :receipt or :disbursement...)
  # configured for an Entry's source_type, or nil when it plays none. The engine's own
  # sources (invoices, bills and credit notes) say theirs themselves.
  class CarryingAmountRole
    def self.call(entry:)
      new(entry: entry).call
    end

    def initialize(entry:)
      @entry = entry
    end

    def call
      return @entry.source&.carrying_amount_role if ENGINE_SOURCES.include?(@entry&.source_type)

      TudlaAccounting.configuration.carrying_amount_sources[@entry&.source_type]
    end

    ENGINE_SOURCES = %w[TudlaAccounting::Document].freeze
  end
end
