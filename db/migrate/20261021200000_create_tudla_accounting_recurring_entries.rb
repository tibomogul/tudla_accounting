# Entries made again and again (rent, subscriptions, depreciation): a template of lines and
# a schedule. RecurringEntryRunner makes each occurrence's entry when it falls due.
class CreateTudlaAccountingRecurringEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_recurring_entries do |t|
      t.references :organization, polymorphic: true, null: false, index: { name: "index_tudla_accounting_recurring_entries_on_organization" }
      t.string :name, null: false
      t.text :particulars, null: false
      t.string :reference
      t.boolean :tax_inclusive, null: false, default: false
      # Every interval weeks, months or years from starts_on; a monthly or yearly one on
      # day_of_month (cut to the month's length), or its last day when that is nil.
      t.string :frequency, null: false
      t.integer :interval, null: false, default: 1
      t.integer :day_of_month
      t.date :starts_on, null: false
      t.date :ends_on
      t.integer :occurrences_limit
      t.integer :occurrences_count, null: false, default: 0
      t.date :next_on # nil once the schedule has run out
      t.boolean :post_automatically, null: false, default: false
      t.boolean :reverse_next_month, null: false, default: false
      t.boolean :active, null: false, default: true
      t.string :last_problem
      t.timestamps
    end
    add_index :tudla_accounting_recurring_entries, %i[active next_on]
    add_check_constraint :tudla_accounting_recurring_entries, "frequency IN ('weekly', 'monthly', 'yearly')", name: "tudla_accounting_recurring_entries_frequency_known"
    add_check_constraint :tudla_accounting_recurring_entries, "interval > 0", name: "tudla_accounting_recurring_entries_interval_positive"

    create_table :tudla_accounting_recurring_entry_lines do |t|
      t.references :recurring_entry, null: false, foreign_key: { to_table: :tudla_accounting_recurring_entries },
                                     index: { name: "index_tudla_accounting_recurring_entry_lines_on_recurring_entry" }
      t.references :account, null: false, foreign_key: { to_table: :tudla_accounting_accounts },
                             index: { name: "index_tudla_accounting_recurring_entry_lines_on_account" }
      t.integer :tally, null: false
      t.bigint :amount_cents, null: false
      t.string :description
      t.references :tax_code, foreign_key: { to_table: :tudla_accounting_tax_codes }, index: { name: "index_tudla_accounting_recurring_entry_lines_on_tax_code" }
      t.bigint :dimension_value_ids, array: true, null: false, default: []
      t.timestamps
    end
    add_check_constraint :tudla_accounting_recurring_entry_lines, "amount_cents > 0", name: "tudla_accounting_recurring_entry_lines_amount_positive"
  end
end
