class CreateTudlaAccountingBankAccountBalances < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_bank_account_balances do |t|
      t.string :name
      t.string :currency
      t.bigint :balance_cents
      t.references :account, null: false, foreign_key: { to_table: :tudla_accounting_accounts }

      t.timestamps
    end
  end
end
