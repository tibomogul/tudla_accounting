# frozen_string_literal: true

module TudlaAccounting
  # Checks whether an Entry originates from a Invoice (by its source_type).
  class IsEntryReceivableChecker
    def self.call(entry:)
      new(entry: entry).call
    end

    def initialize(entry:)
      @entry = entry
    end

    def call
      @entry&.source_type == "Invoice"
    end
  end
end
