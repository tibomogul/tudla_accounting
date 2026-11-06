class AddTaxablePaymentsToTudlaAccountingContacts < ActiveRecord::Migration[8.1]
  # Whether payments to a contact go on a taxable payments report, such as Australia's
  # taxable payments annual report (TPAR).
  def change
    add_column :tudla_accounting_contacts, :taxable_payments, :boolean, null: false, default: false
  end
end
