# Rules for recording bank statement lines the books don't have yet: a line whose
# description contains some text (and, optionally, money in or out, within an amount
# range) is recorded against an account, with a tax code and dimension values.
class CreateTudlaAccountingBankRules < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_bank_rules do |t|
      t.references :organization, polymorphic: true, null: false, index: { name: "index_tudla_accounting_bank_rules_on_organization" }
      t.string :name, null: false
      t.integer :position, null: false, default: 0
      t.references :account, foreign_key: { to_table: :tudla_accounting_accounts }, index: { name: "index_tudla_accounting_bank_rules_on_account" } # nil: every bank account
      t.string :description_contains, null: false
      t.string :direction # in, out, or nil for either
      t.bigint :amount_min_cents
      t.bigint :amount_max_cents
      t.references :counter_account, null: false, foreign_key: { to_table: :tudla_accounting_accounts }, index: { name: "index_tudla_accounting_bank_rules_on_counter_account" }
      t.references :tax_code, foreign_key: { to_table: :tudla_accounting_tax_codes }, index: { name: "index_tudla_accounting_bank_rules_on_tax_code" }
      t.bigint :dimension_value_ids, array: true, null: false, default: []
      t.string :particulars
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_check_constraint :tudla_accounting_bank_rules, "direction IS NULL OR direction IN ('in', 'out')", name: "tudla_accounting_bank_rules_direction_known"
  end
end
