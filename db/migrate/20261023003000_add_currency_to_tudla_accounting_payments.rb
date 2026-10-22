# A payment through a bank account held in a foreign currency: its amount is in that
# currency, and exchange_rate (how many of the organization's currency one unit of it was
# worth) turns it into the organization's for posting. Both nil for one in the
# organization's own.
class AddCurrencyToTudlaAccountingPayments < ActiveRecord::Migration[8.1]
  def change
    add_column :tudla_accounting_payments, :currency, :string, limit: 3
    add_column :tudla_accounting_payments, :exchange_rate, :decimal, precision: 24, scale: 8
    add_check_constraint :tudla_accounting_payments, "(currency IS NULL) = (exchange_rate IS NULL) AND (exchange_rate IS NULL OR exchange_rate > 0)",
                         name: "tudla_accounting_payments_foreign_currency_rated"
  end
end
