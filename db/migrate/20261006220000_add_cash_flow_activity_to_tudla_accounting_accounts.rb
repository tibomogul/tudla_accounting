# Where an account's cash movements go in the cash flow statement: operating, investing
# or financing. Blank inherits from the parent account, then defaults by category.
class AddCashFlowActivityToTudlaAccountingAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :tudla_accounting_accounts, :cash_flow_activity, :integer
    add_check_constraint :tudla_accounting_accounts, "cash_flow_activity IS NULL OR cash_flow_activity IN (0, 1, 2)",
                         name: "tudla_accounting_accounts_cash_flow_activity_known"
  end
end
