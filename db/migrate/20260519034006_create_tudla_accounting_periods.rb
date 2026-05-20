class CreateTudlaAccountingPeriods < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_periods do |t|
      t.datetime :from_date, null: false
      t.datetime :thru_date, null: false
      t.string :ancestry, null: false, default: "/"
      t.integer :ancestry_depth, null: false, default: 0
      t.integer :children_count, null: false, default: 0
      t.references :organization, polymorphic: true, null: false

      t.timestamps
    end

    add_index :tudla_accounting_periods, :ancestry
  end
end
