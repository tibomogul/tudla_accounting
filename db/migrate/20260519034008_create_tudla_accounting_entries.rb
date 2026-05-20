class CreateTudlaAccountingEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_entries do |t|
      t.text :particulars
      t.datetime :transacted_at
      t.datetime :posted_at
      t.references :source, polymorphic: true, null: true
      t.references :related, polymorphic: true, null: true
      t.references :organization, polymorphic: true, null: false

      t.timestamps
    end

    add_index :tudla_accounting_entries, :transacted_at
    add_index :tudla_accounting_entries, :posted_at
  end
end
