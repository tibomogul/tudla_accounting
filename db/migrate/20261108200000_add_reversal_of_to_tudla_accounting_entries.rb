# Which entry a reversal reverses, as a column rather than its "Reversal of: " particulars
# (Entry#reverse!). Each entry can be reversed once, so the index is unique.
#
# Reversals made before this are found by those particulars and the entry they're related
# to; if an entry somehow has two, the first is taken.
class AddReversalOfToTudlaAccountingEntries < ActiveRecord::Migration[8.1]
  def up
    add_reference :tudla_accounting_entries, :reversal_of, foreign_key: { to_table: :tudla_accounting_entries },
                  index: { unique: true, name: "tudla_accounting_entries_reversal_of_unique_key" }

    TudlaAccounting::DatabaseProtection.allowing_posted_changes(connection) do
      execute <<~SQL
        UPDATE tudla_accounting_entries SET reversal_of_id = firsts.related_id
        FROM (SELECT DISTINCT ON (related_id) id, related_id FROM tudla_accounting_entries
              WHERE related_type = 'TudlaAccounting::Entry' AND particulars LIKE 'Reversal of: %' AND posted_at IS NOT NULL
              ORDER BY related_id, id) AS firsts
        WHERE tudla_accounting_entries.id = firsts.id
      SQL
    end
  end

  def down
    TudlaAccounting::DatabaseProtection.allowing_posted_changes(connection) do
      remove_reference :tudla_accounting_entries, :reversal_of, foreign_key: { to_table: :tudla_accounting_entries },
                       index: { unique: true, name: "tudla_accounting_entries_reversal_of_unique_key" }
    end
  end
end
