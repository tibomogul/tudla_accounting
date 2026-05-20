class CreateTudlaAccountingForexRates < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_forex_rates do |t|
      t.string :from
      t.string :to
      t.decimal :rate, precision: 24, scale: 8
      t.integer :year
      t.integer :month
      t.integer :day

      t.timestamps
    end
  end
end
