class AddWithheldOnToTudlaAccountingWithholdingCodes < ActiveRecord::Migration[8.1]
  # When tax under the code is withheld from a supplier: when their bill is approved, or
  # when they're paid (Australia's no-ABN withholding).
  def change
    add_column :tudla_accounting_withholding_codes, :withheld_on, :string, null: false, default: "approval"
    add_check_constraint :tudla_accounting_withholding_codes, "withheld_on IN ('approval', 'payment')", name: "tudla_accounting_withholding_codes_withheld_on"
  end
end
