# frozen_string_literal: true

module TudlaAccounting
  # Checks whether an Entry originates from a Bill (by its source_type).
  class IsEntryPayableChecker
    def self.call(entry:)
      new(entry: entry).call
    end

    def initialize(entry:)
      @entry = entry
    end

    def call
      @entry&.source_type == "Bill"
    end
  end
end
