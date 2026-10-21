# Accounts no longer used can be made inactive: they keep their history, and stop being
# offered for new entries.
class AddActiveToTudlaAccountingAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :tudla_accounting_accounts, :active, :boolean, null: false, default: true
  end
end
