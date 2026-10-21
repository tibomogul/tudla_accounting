# frozen_string_literal: true

module TudlaAccounting
  # A counter per organization and name, e.g. "entry:" for the entries numbered in the
  # organization's own series. next! takes the row's lock until the transaction ends, so
  # numbers are handed out one at a time, and a rolled-back transaction gives its number
  # back: no gaps.
  class Sequence < ApplicationRecord
    belongs_to :organization, polymorphic: true

    # The next value of the organization's sequence of that name, starting at 1.
    def self.next!(organization, name)
      connection.select_value(sanitize_sql_array([ <<~SQL, organization.class.polymorphic_name, organization.id, name.to_s ]))
        INSERT INTO tudla_accounting_sequences (organization_type, organization_id, name, last_value, created_at, updated_at)
        VALUES (?, ?, ?, 1, NOW(), NOW())
        ON CONFLICT (organization_type, organization_id, name)
        DO UPDATE SET last_value = tudla_accounting_sequences.last_value + 1, updated_at = NOW()
        RETURNING last_value
      SQL
    end
  end
end
