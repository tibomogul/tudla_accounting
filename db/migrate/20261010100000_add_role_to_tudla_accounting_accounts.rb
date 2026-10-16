# The accounts the engine treats specially (receivables, payables, retained earnings,
# exchange gains and losses) are marked by role on the account, one of each per
# organization.
class AddRoleToTudlaAccountingAccounts < ActiveRecord::Migration[8.1]
  ROLES = %w[receivable payable retained_earnings unrealized_fx_gain realized_fx_gain].freeze

  def change
    add_column :tudla_accounting_accounts, :role, :string
    add_index :tudla_accounting_accounts, %i[organization_type organization_id role], unique: true, where: "role IS NOT NULL",
              name: "index_tudla_accounting_accounts_on_organization_and_role"
    add_check_constraint :tudla_accounting_accounts, "role IN (#{ROLES.map { |role| connection.quote(role) }.join(', ')})",
                         name: "tudla_accounting_accounts_role_known"
  end
end
