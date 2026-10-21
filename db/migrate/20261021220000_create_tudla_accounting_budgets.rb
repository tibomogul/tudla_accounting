# Budgets: named plans for a financial year, each an amount per income or expense
# account per month. A year can have several (an original and a revised one, say), one
# of them its main budget.
class CreateTudlaAccountingBudgets < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_budgets do |t|
      t.references :organization, polymorphic: true, null: false, index: false
      t.references :period, null: false, foreign_key: { to_table: :tudla_accounting_periods }, index: { name: "index_tudla_accounting_budgets_on_period" } # the year
      t.string :name, null: false
      t.boolean :main, null: false, default: false
      t.timestamps
    end
    add_index :tudla_accounting_budgets, %i[organization_type organization_id period_id name], unique: true, name: "index_tudla_accounting_budgets_on_name"
    add_index :tudla_accounting_budgets, %i[organization_type organization_id period_id], unique: true, where: "main", name: "index_tudla_accounting_budgets_one_main"

    # An account's amount for a month, on the account's own side (zero is no line).
    create_table :tudla_accounting_budget_lines do |t|
      t.references :budget, null: false, foreign_key: { to_table: :tudla_accounting_budgets, on_delete: :cascade }, index: false
      t.references :account, null: false, foreign_key: { to_table: :tudla_accounting_accounts }, index: { name: "index_tudla_accounting_budget_lines_on_account" }
      t.references :period, null: false, foreign_key: { to_table: :tudla_accounting_periods }, index: { name: "index_tudla_accounting_budget_lines_on_period" } # the month
      t.bigint :amount_cents, null: false
    end
    add_index :tudla_accounting_budget_lines, %i[budget_id account_id period_id], unique: true, name: "index_tudla_accounting_budget_lines_unique"
  end
end
