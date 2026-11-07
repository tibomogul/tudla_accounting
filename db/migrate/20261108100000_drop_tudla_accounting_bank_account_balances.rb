# Nothing created these rows or showed them: posting only updated balances someone had
# added by hand, comparing the account's currency with base_currency. A foreign bank
# account's own-currency amounts are on its ledger lines (foreign exchange details).
class DropTudlaAccountingBankAccountBalances < ActiveRecord::Migration[8.1]
  def change
    drop_table :tudla_accounting_bank_account_balances do |t|
      t.string :name
      t.string :currency
      t.bigint :balance_cents
      t.references :account, null: false, foreign_key: { to_table: :tudla_accounting_accounts }, index: { unique: true, name: "tudla_accounting_bank_account_balances_unique_key" }

      t.timestamps
    end
  end
end
