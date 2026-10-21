# The organization's customers and suppliers: who documents are to or from, and the
# party their receivables and payables are owed by or to.
class CreateTudlaAccountingContacts < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_contacts do |t|
      t.references :organization, polymorphic: true, null: false, index: false
      t.string :name, null: false
      t.string :kind, null: false, default: "customer" # customer, supplier or both
      t.string :email
      t.string :phone
      t.text :address
      t.string :tax_number
      t.integer :payment_terms_days # documents are due this many days after their date
      t.references :default_account, foreign_key: { to_table: :tudla_accounting_accounts }, index: { name: "index_tudla_accounting_contacts_on_default_account" }
      t.references :default_tax_code, foreign_key: { to_table: :tudla_accounting_tax_codes }, index: { name: "index_tudla_accounting_contacts_on_default_tax_code" }
      t.boolean :active, null: false, default: true
      t.text :notes
      t.timestamps
    end
    add_index :tudla_accounting_contacts, %i[organization_type organization_id name], name: "index_tudla_accounting_contacts_on_name"
    add_check_constraint :tudla_accounting_contacts, "kind IN ('customer', 'supplier', 'both')", name: "tudla_accounting_contacts_kind_known"
    add_check_constraint :tudla_accounting_contacts, "payment_terms_days IS NULL OR payment_terms_days >= 0", name: "tudla_accounting_contacts_terms_not_negative"
  end
end
