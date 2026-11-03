# The tax a customer withheld from a payment, with each amount's row saying which payment
# it came from and when its certificate (Form 2307, in the Philippines) came in.
class AddWithholdingToTudlaAccountingPayments < ActiveRecord::Migration[8.1]
  def change
    add_column :tudla_accounting_payments, :withheld_cents, :bigint, null: false, default: 0
    add_check_constraint :tudla_accounting_payments, "withheld_cents >= 0", name: "tudla_accounting_payments_withheld_not_negative"
    add_reference :tudla_accounting_withheld_taxes, :payment, foreign_key: { to_table: :tudla_accounting_payments }, index: { name: "index_tudla_accounting_withheld_taxes_on_payment" }
    add_column :tudla_accounting_withheld_taxes, :certificate_received_on, :date
  end
end
