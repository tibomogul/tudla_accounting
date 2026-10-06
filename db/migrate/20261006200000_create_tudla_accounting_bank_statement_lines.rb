# Bank statement lines imported for a bank account, and the posted ledger lines each is
# matched to. Posted lines can't be changed, so a match is a row of its own.
class CreateTudlaAccountingBankStatementLines < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_bank_statement_lines do |t|
      t.references :organization, polymorphic: true, null: false, index: false
      t.references :account, null: false, foreign_key: { to_table: :tudla_accounting_accounts }, index: false
      t.date :occurred_on, null: false
      t.string :description, null: false
      t.string :reference
      t.bigint :amount_cents, null: false
      t.string :currency, null: false
      t.bigint :balance_cents
      t.string :external_id, null: false
      t.timestamps
    end
    add_index :tudla_accounting_bank_statement_lines, %i[account_id occurred_on]
    add_index :tudla_accounting_bank_statement_lines, %i[account_id external_id], unique: true, name: "tudla_accounting_bank_statement_lines_unique_key"
    add_check_constraint :tudla_accounting_bank_statement_lines, "amount_cents <> 0", name: "tudla_accounting_bank_statement_lines_amount_not_zero"

    create_table :tudla_accounting_bank_matches do |t|
      t.references :organization, polymorphic: true, null: false, index: false
      t.references :bank_statement_line, null: false, foreign_key: { to_table: :tudla_accounting_bank_statement_lines }
      t.references :detail, null: false, foreign_key: { to_table: :tudla_accounting_details }, index: { unique: true }
      t.timestamps
    end
  end
end
