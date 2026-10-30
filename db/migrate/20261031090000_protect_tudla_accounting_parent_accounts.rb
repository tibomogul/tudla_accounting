# An account with sub-accounts holds what they add up to: on PostgreSQL, triggers refuse
# posting to one, and sub-accounts beneath an account with posted lines of its own (see
# TudlaAccounting::DatabaseProtection). Books that already break this keep what they hold;
# bin/rails tudla_accounting:balances:check names those accounts.
class ProtectTudlaAccountingParentAccounts < ActiveRecord::Migration[8.1]
  ADDED = %w[tudla_accounting_protect_parent_entries tudla_accounting_protect_parent_details tudla_accounting_protect_sub_accounts].freeze

  def up
    TudlaAccounting::DatabaseProtection.install!(connection)
  end

  def down
    return unless TudlaAccounting::DatabaseProtection.supported?(connection)

    execute(ADDED.map { |name| <<~SQL }.join)
      DROP TRIGGER IF EXISTS #{name} ON #{TudlaAccounting::DatabaseProtection::TRIGGERS.fetch(name)};
      DROP FUNCTION IF EXISTS #{name}();
    SQL
  end
end
