# A contact's postal or ZIP code, apart from the address, for forms with a box for it such
# as the BIR's Form 2307.
class AddPostalCodeToTudlaAccountingContacts < ActiveRecord::Migration[8.1]
  def change
    add_column :tudla_accounting_contacts, :postal_code, :string
  end
end
