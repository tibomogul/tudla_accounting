# How a tax code's lines are treated: taxed at its rate (standard), zero-rated (taxable at
# 0%, such as exports) or exempt (outside the tax). The last two have no rate; returns
# and the sales journal tell them apart.
class AddTreatmentToTudlaAccountingTaxCodes < ActiveRecord::Migration[8.1]
  def change
    add_column :tudla_accounting_tax_codes, :treatment, :integer, null: false, default: 0
    add_check_constraint :tudla_accounting_tax_codes, "treatment = ANY (ARRAY[0, 1, 2])", name: "tudla_accounting_tax_codes_treatment_known"
    add_check_constraint :tudla_accounting_tax_codes, "treatment = 0 OR rate = 0::numeric", name: "tudla_accounting_tax_codes_untaxed_without_rate"
  end
end
