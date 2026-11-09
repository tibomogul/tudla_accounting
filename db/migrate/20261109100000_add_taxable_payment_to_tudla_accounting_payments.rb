class AddTaxablePaymentToTudlaAccountingPayments < ActiveRecord::Migration[8.1]
  # Whether a payment to a supplier, or a refund from one, goes on the taxable payments
  # report (Australia's TPAR): taken from the contact's flag when it is made, so changing the
  # flag later leaves the years already reported as they were. Payments already made take
  # their contact's flag as it is now.
  def up
    add_column :tudla_accounting_payments, :taxable_payment, :boolean, null: false, default: false
    execute <<~SQL
      UPDATE tudla_accounting_payments SET taxable_payment = TRUE
      WHERE kind IN ('paid', 'supplier_refund')
        AND contact_id IN (SELECT id FROM tudla_accounting_contacts WHERE taxable_payments)
    SQL
  end

  def down
    remove_column :tudla_accounting_payments, :taxable_payment
  end
end
