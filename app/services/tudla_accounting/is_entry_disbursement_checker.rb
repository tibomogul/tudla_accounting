# frozen_string_literal: true

module TudlaAccounting
  # Checks whether an Entry originates from a Disbursement (by its source_type).
  class IsEntryDisbursementChecker
    def self.call(entry:)
      new(entry: entry).call
    end

    def initialize(entry:)
      @entry = entry
    end

    def call
      @entry&.source_type == "Disbursement"
    end
  end
end
