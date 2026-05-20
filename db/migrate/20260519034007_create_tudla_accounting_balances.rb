class CreateTudlaAccountingBalances < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_balances do |t|
      t.references :account, null: true, foreign_key: { to_table: :tudla_accounting_accounts }
      t.references :period, null: true, foreign_key: { to_table: :tudla_accounting_periods }
      t.bigint :starting_amount_cents
      t.bigint :current_amount_cents
      t.bigint :ending_amount_cents
      t.string :currency
      t.references :organization, polymorphic: true, null: false

      t.timestamps
    end
  end
end
