class CreateTudlaAccountingCarryingAmountForexes < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_carrying_amount_forexes do |t|
      t.references :carrying_amount, null: false, foreign_key: { to_table: :tudla_accounting_carrying_amounts }, index: { unique: true }
      t.bigint :other_currency_amount_cents, default: 0, null: false
      t.string :other_currency, limit: 3, default: "XXX", null: false
      t.decimal :transaction_rate, precision: 24, scale: 8
      t.date :conversion_date

      t.timestamps
    end
  end
end
