# Lets other systems create entries safely more than once (a retried job, a replayed
# webhook): an entry with the same key in the same organization is returned instead of
# being created again.
class AddIdempotencyKeyToTudlaAccountingEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :tudla_accounting_entries, :idempotency_key, :string
    add_index :tudla_accounting_entries, %i[organization_type organization_id idempotency_key], unique: true,
              where: "idempotency_key IS NOT NULL", name: "tudla_accounting_entries_idempotency_key"
  end
end
