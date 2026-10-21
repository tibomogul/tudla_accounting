# Journal numbers and references. A posted entry gets the next number of its series (the
# entry_number_series setting: one run per organization by default), counted in
# tudla_accounting_sequences, so posted entries, which are never deleted, are numbered
# without gaps. A reference is free text from elsewhere: a cheque number, the
# supplier's invoice number.
#
# Entries posted before this are numbered in the order they were created, in the
# organization's series.
class AddNumberAndReferenceToTudlaAccountingEntries < ActiveRecord::Migration[8.1]
  def up
    create_table :tudla_accounting_sequences do |t|
      t.string :organization_type, null: false
      t.bigint :organization_id, null: false
      t.string :name, null: false
      t.bigint :last_value, null: false
      t.timestamps
    end
    add_index :tudla_accounting_sequences, %i[organization_type organization_id name], unique: true,
              name: "tudla_accounting_sequences_unique_key"

    add_column :tudla_accounting_entries, :number, :bigint
    add_column :tudla_accounting_entries, :number_series, :string, null: false, default: ""
    add_column :tudla_accounting_entries, :reference, :string

    TudlaAccounting::DatabaseProtection.allowing_posted_changes(connection) do
      execute <<~SQL
        UPDATE tudla_accounting_entries SET number = numbered.number
        FROM (SELECT id, ROW_NUMBER() OVER (PARTITION BY organization_type, organization_id ORDER BY id) AS number
              FROM tudla_accounting_entries WHERE posted_at IS NOT NULL) AS numbered
        WHERE tudla_accounting_entries.id = numbered.id
      SQL
    end
    execute <<~SQL
      INSERT INTO tudla_accounting_sequences (organization_type, organization_id, name, last_value, created_at, updated_at)
      SELECT organization_type, organization_id, 'entry:', MAX(number), NOW(), NOW()
      FROM tudla_accounting_entries WHERE number IS NOT NULL GROUP BY organization_type, organization_id
    SQL

    add_index :tudla_accounting_entries, %i[organization_type organization_id number_series number], unique: true,
              where: "number IS NOT NULL", name: "tudla_accounting_entries_number_unique_key"
    add_check_constraint :tudla_accounting_entries, "(posted_at IS NULL) = (number IS NULL)", name: "tudla_accounting_entries_numbered_when_posted"
  end

  def down
    remove_check_constraint :tudla_accounting_entries, name: "tudla_accounting_entries_numbered_when_posted"
    remove_index :tudla_accounting_entries, name: "tudla_accounting_entries_number_unique_key"
    TudlaAccounting::DatabaseProtection.allowing_posted_changes(connection) do
      remove_column :tudla_accounting_entries, :reference
      remove_column :tudla_accounting_entries, :number_series
      remove_column :tudla_accounting_entries, :number
    end
    drop_table :tudla_accounting_sequences
  end
end
