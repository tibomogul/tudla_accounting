# Payments and credit notes are applied to invoices and bills through allocations; what
# isn't applied stays as a credit for the customer or supplier. See
# TudlaAccounting::Allocator. Existing payments are converted by AllocationBackfill.
class CreateTudlaAccountingAllocations < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_allocations do |t|
      t.references :organization, polymorphic: true, null: false
      t.references :from, null: false, foreign_key: { to_table: :tudla_accounting_carrying_amounts }
      t.references :to, null: false, foreign_key: { to_table: :tudla_accounting_carrying_amounts }
      t.bigint :amount_cents, null: false
      t.bigint :other_currency_cents
      t.datetime :allocated_at, null: false
      t.datetime :reversed_at
      t.references :realized_entry, foreign_key: { to_table: :tudla_accounting_entries }
      t.timestamps
    end
    add_check_constraint :tudla_accounting_allocations, "amount_cents > 0", name: "tudla_accounting_allocations_amount_positive"

    reversible { |direction| direction.up { TudlaAccounting::AllocationBackfill.call } }
  end
end
