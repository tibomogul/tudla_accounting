# The demo's customers, and the invoices and payments it records against them, as a
# host app's would be: the entries' sources, which the books track as receivables.
class CreateDemoCustomersAndInvoices < ActiveRecord::Migration[8.1]
  def change
    create_table :demo_customers do |t|
      t.string :name, null: false
      t.timestamps
    end
    create_table :demo_invoices do |t|
      t.references :customer, null: false, foreign_key: { to_table: :demo_customers }
      t.datetime :due_date
      t.timestamps
    end
    create_table :demo_payments do |t|
      t.references :customer, null: false, foreign_key: { to_table: :demo_customers }
      t.timestamps
    end
  end
end
