class CreateTudlaAccountingForeignExchanges < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_foreign_exchanges do |t|
      t.references :detail, null: false, foreign_key: { to_table: :tudla_accounting_details }
      t.decimal :rate, precision: 24, scale: 8
      t.bigint :other_currency_cents
      t.string :other_currency

      t.timestamps
    end
  end
end
