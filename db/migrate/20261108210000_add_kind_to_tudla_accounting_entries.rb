# What an entry the engine posts by itself is, as a column rather than its particulars:
# realized_exchange (a payment's exchange difference, Allocator), and revaluation and
# revaluation_reversal (RevaluationEntryGenerator). Everything else has none.
#
# Entries posted before this are found by their particulars ("Realized exchange ",
# "Revaluation of ", "Reversal of Revaluation of "), the entry they're related to and
# having no source, as the engine posted them.
class AddKindToTudlaAccountingEntries < ActiveRecord::Migration[8.1]
  KINDS = { "realized_exchange" => "Realized exchange %", "revaluation" => "Revaluation of %", "revaluation_reversal" => "Reversal of Revaluation of %" }.freeze

  def up
    add_column :tudla_accounting_entries, :kind, :string
    add_check_constraint :tudla_accounting_entries, "kind IN (#{KINDS.keys.map { |kind| connection.quote(kind) }.join(', ')})",
                         name: "tudla_accounting_entries_kind"

    TudlaAccounting::DatabaseProtection.allowing_posted_changes(connection) do
      KINDS.each do |kind, pattern|
        execute <<~SQL
          UPDATE tudla_accounting_entries SET kind = #{connection.quote(kind)}
          WHERE related_type = 'TudlaAccounting::Entry' AND source_type IS NULL AND particulars LIKE #{connection.quote(pattern)}
        SQL
      end
    end
  end

  def down
    remove_check_constraint :tudla_accounting_entries, name: "tudla_accounting_entries_kind"
    TudlaAccounting::DatabaseProtection.allowing_posted_changes(connection) { remove_column :tudla_accounting_entries, :kind }
  end
end
