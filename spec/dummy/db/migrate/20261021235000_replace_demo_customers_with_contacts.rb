# The demo's customers are the engine's contacts now, and its invoices the engine's own;
# its payments stay a host model (applied to those invoices) and name the contact. Books
# seeded before this need reseeding (bin/setup --reset).
class ReplaceDemoCustomersWithContacts < ActiveRecord::Migration[8.1]
  def up
    drop_table :demo_invoices
    execute "DELETE FROM demo_payments"
    remove_foreign_key :demo_payments, :demo_customers, column: :customer_id
    add_foreign_key :demo_payments, :tudla_accounting_contacts, column: :customer_id
    drop_table :demo_customers
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
