class CreateTudlaAccountingCarryingAmounts < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_carrying_amounts do |t|
      t.references :detail, null: false, foreign_key: { to_table: :tudla_accounting_details }
      t.bigint :amount_cents
      t.integer :carrying_amount_type
      t.datetime :due_date
      t.references :related_party, polymorphic: true, null: false

      t.timestamps
    end
  end
end
