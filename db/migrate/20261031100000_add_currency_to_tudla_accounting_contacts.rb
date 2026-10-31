# The currency a contact's new invoices, bills and payments start in; nil for the
# organization's own.
class AddCurrencyToTudlaAccountingContacts < ActiveRecord::Migration[8.1]
  def change
    add_column :tudla_accounting_contacts, :currency, :string, limit: 3
  end
end
