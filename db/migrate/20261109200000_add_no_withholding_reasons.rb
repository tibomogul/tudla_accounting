class AddNoWithholdingReasons < ActiveRecord::Migration[8.1]
  # Why tax isn't withheld from a payment to a supplier whose code is withheld on payment
  # (Australia's no-ABN withholding): a code's limit at or under which a supply isn't
  # withheld from, a supplier's exemption and the date of their statement, and the reason
  # each payment made without the tax keeps.
  def change
    add_column :tudla_accounting_withholding_codes, :exempt_up_to_cents, :bigint
    add_column :tudla_accounting_contacts, :withholding_exemption, :string
    add_column :tudla_accounting_contacts, :withholding_statement_on, :date
    add_column :tudla_accounting_payments, :not_withheld_reason, :string
  end
end
