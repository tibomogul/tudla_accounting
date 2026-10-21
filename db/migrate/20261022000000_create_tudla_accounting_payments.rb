# Money received from customers and paid to suppliers, through a bank or cash account,
# applied to their invoices and bills.
class CreateTudlaAccountingPayments < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_payments do |t|
      t.references :organization, polymorphic: true, null: false, index: false
      t.string :kind, null: false # received or paid
      t.string :status, null: false, default: "posted" # posted or void
      t.references :contact, null: false, foreign_key: { to_table: :tudla_accounting_contacts }, index: { name: "index_tudla_accounting_payments_on_contact" }
      t.references :account, null: false, foreign_key: { to_table: :tudla_accounting_accounts }, index: { name: "index_tudla_accounting_payments_on_account" }
      t.date :paid_on, null: false
      t.bigint :amount_cents, null: false
      t.string :reference
      t.text :notes
      t.references :entry, foreign_key: { to_table: :tudla_accounting_entries }, index: { name: "index_tudla_accounting_payments_on_entry", unique: true }
      t.date :voided_on
      t.string :void_reason
      t.timestamps
    end
    add_index :tudla_accounting_payments, %i[organization_type organization_id paid_on], name: "index_tudla_accounting_payments_on_paid_on"
    add_check_constraint :tudla_accounting_payments, "kind IN ('received', 'paid')", name: "tudla_accounting_payments_kind_known"
    add_check_constraint :tudla_accounting_payments, "status IN ('posted', 'void')", name: "tudla_accounting_payments_status_known"
    add_check_constraint :tudla_accounting_payments, "amount_cents > 0", name: "tudla_accounting_payments_amount_positive"
  end
end
