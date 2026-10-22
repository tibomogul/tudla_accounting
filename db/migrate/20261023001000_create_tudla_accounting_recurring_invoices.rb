# Invoices made again and again (a retainer, a subscription): a customer, lines and a
# schedule. RecurringInvoiceRunner makes each occurrence's invoice when it falls due, as a
# draft, approved, or approved and emailed (issue).
class CreateTudlaAccountingRecurringInvoices < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_recurring_invoices do |t|
      t.references :organization, polymorphic: true, null: false, index: { name: "index_tudla_accounting_recurring_invoices_on_organization" }
      t.references :contact, null: false, foreign_key: { to_table: :tudla_accounting_contacts }, index: { name: "index_tudla_accounting_recurring_invoices_on_contact" }
      t.string :name, null: false
      t.string :reference
      t.text :notes
      t.boolean :tax_inclusive, null: false, default: false
      t.integer :due_days # days from the invoice's date to its due date; nil: the customer's terms
      # Every interval weeks, months or years from starts_on (see RecurringSchedule).
      t.string :frequency, null: false
      t.integer :interval, null: false, default: 1
      t.integer :day_of_month
      t.date :starts_on, null: false
      t.date :ends_on
      t.integer :occurrences_limit
      t.integer :occurrences_count, null: false, default: 0
      t.date :next_on # nil once the schedule has run out
      t.string :issue, null: false, default: "draft"
      t.boolean :active, null: false, default: true
      t.string :last_problem
      t.timestamps
    end
    add_index :tudla_accounting_recurring_invoices, %i[active next_on]
    add_check_constraint :tudla_accounting_recurring_invoices, "frequency IN ('weekly', 'monthly', 'yearly')", name: "tudla_accounting_recurring_invoices_frequency_known"
    add_check_constraint :tudla_accounting_recurring_invoices, "interval > 0", name: "tudla_accounting_recurring_invoices_interval_positive"
    add_check_constraint :tudla_accounting_recurring_invoices, "issue IN ('draft', 'approve', 'email')", name: "tudla_accounting_recurring_invoices_issue_known"
    add_check_constraint :tudla_accounting_recurring_invoices, "due_days IS NULL OR due_days >= 0", name: "tudla_accounting_recurring_invoices_due_days_not_negative"

    create_table :tudla_accounting_recurring_invoice_lines do |t|
      t.references :recurring_invoice, null: false, foreign_key: { to_table: :tudla_accounting_recurring_invoices },
                                       index: { name: "index_tudla_accounting_recurring_invoice_lines_on_template" }
      t.integer :position, null: false, default: 0
      t.string :description, null: false
      t.decimal :quantity, precision: 15, scale: 4, null: false, default: 1
      t.bigint :unit_price_cents, null: false, default: 0
      t.references :account, null: false, foreign_key: { to_table: :tudla_accounting_accounts },
                             index: { name: "index_tudla_accounting_recurring_invoice_lines_on_account" }
      t.references :tax_code, foreign_key: { to_table: :tudla_accounting_tax_codes }, index: { name: "index_tudla_accounting_recurring_invoice_lines_on_tax_code" }
      t.bigint :dimension_value_ids, array: true, null: false, default: []
      t.timestamps
    end
    add_check_constraint :tudla_accounting_recurring_invoice_lines, "quantity >= 0 AND unit_price_cents >= 0", name: "tudla_accounting_recurring_invoice_lines_not_negative"

    add_reference :tudla_accounting_documents, :recurring_invoice, foreign_key: { to_table: :tudla_accounting_recurring_invoices, on_delete: :nullify },
                                                                   index: { name: "index_tudla_accounting_documents_on_recurring_invoice" }
  end
end
