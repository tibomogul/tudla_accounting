# Database-level guarantees for the ledger, so a stray job, console session or raw SQL
# can't corrupt it: unique keys, value checks, and (on PostgreSQL) posted entries that
# can't be changed or deleted.
class AddIntegrityConstraintsToTudlaAccounting < ActiveRecord::Migration[8.1]
  UNIQUE_KEYS = {
    tudla_accounting_balances: %i[account_id period_id],
    tudla_accounting_accounts: %i[organization_type organization_id code],
    tudla_accounting_carrying_amounts: %i[detail_id],
    tudla_accounting_foreign_exchanges: %i[detail_id],
    tudla_accounting_bank_account_balances: %i[account_id],
    tudla_accounting_forex_rates: %i[from to year month day]
  }.freeze

  # Replaced by unique indexes on the same columns.
  PLAIN_INDEXES = {
    tudla_accounting_carrying_amounts: :detail_id,
    tudla_accounting_foreign_exchanges: :detail_id,
    tudla_accounting_bank_account_balances: :account_id
  }.freeze

  CHECKS = {
    tudla_accounting_details: { "amount_cents > 0" => "tudla_accounting_details_amount_positive",
                                "tally IN (0, 1)" => "tudla_accounting_details_tally_known" },
    tudla_accounting_accounts: { "category IN (0, 1, 2, 3, 4)" => "tudla_accounting_accounts_category_known" },
    tudla_accounting_carrying_amounts: { "carrying_amount_type IN (0, 1)" => "tudla_accounting_carrying_amounts_type_known" }
  }.freeze

  def up
    refuse_existing_violations

    PLAIN_INDEXES.each { |table, column| remove_index table, column if index_exists?(table, column, unique: false) }
    UNIQUE_KEYS.each { |table, columns| add_index table, columns, unique: true, name: "#{table}_unique_key" }
    CHECKS.each { |table, checks| checks.each { |expression, name| add_check_constraint table, expression, name: name } }

    create_posted_entry_triggers if postgresql?
  end

  def down
    drop_posted_entry_triggers if postgresql?
    CHECKS.each { |table, checks| checks.each_value { |name| remove_check_constraint table, name: name } }
    UNIQUE_KEYS.each_key { |table| remove_index table, name: "#{table}_unique_key" }
    PLAIN_INDEXES.each { |table, column| add_index table, column }
  end

  private

  def postgresql?
    connection.adapter_name.match?(/postg/i)
  end

  # Clear messages instead of a database error halfway through, listing what to fix.
  def refuse_existing_violations
    problems = UNIQUE_KEYS.filter_map do |table, columns|
      list = columns.map { |column| connection.quote_column_name(column) }.join(", ")
      duplicates = select_rows("SELECT #{list}, COUNT(*) FROM #{table} GROUP BY #{list} HAVING COUNT(*) > 1 LIMIT 5")
      "#{table} has duplicate #{columns.join('/')}: #{duplicates.map { |row| row[0..-2].join('/') }.join('; ')}" if duplicates.any?
    end
    CHECKS.each do |table, checks|
      checks.each_key do |expression|
        count = select_value("SELECT COUNT(*) FROM #{table} WHERE NOT (#{expression})").to_i
        problems << "#{table} has #{count} rows where #{expression} is not true" if count.positive?
      end
    end
    raise ActiveRecord::MigrationError, "Fix these before adding the ledger's constraints:\n#{problems.join("\n")}" if problems.any?
  end

  # A posted entry and its lines are part of the books: correct them by reversing.
  # See TudlaAccounting::DatabaseProtection (also reinstalled after db:schema:load).
  def create_posted_entry_triggers
    TudlaAccounting::DatabaseProtection.install!(connection)
  end

  def drop_posted_entry_triggers
    TudlaAccounting::DatabaseProtection.uninstall!(connection)
  end
end
