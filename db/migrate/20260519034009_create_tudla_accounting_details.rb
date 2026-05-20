class CreateTudlaAccountingDetails < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_details do |t|
      t.references :entry, null: true, foreign_key: { to_table: :tudla_accounting_entries }
      t.references :balance, null: true, foreign_key: { to_table: :tudla_accounting_balances }
      t.references :account, null: true, foreign_key: { to_table: :tudla_accounting_accounts }
      t.integer :tally
      t.bigint :amount_cents
      t.string :currency
      t.references :organization, polymorphic: true, null: false

      t.timestamps
    end
  end
end
