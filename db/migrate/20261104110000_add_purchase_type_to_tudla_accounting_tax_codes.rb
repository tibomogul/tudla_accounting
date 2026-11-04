# What a purchases code's taxed lines are bought as: services, capital goods or other
# goods, as the Philippines' summary list of purchases splits them. None until it's set.
class AddPurchaseTypeToTudlaAccountingTaxCodes < ActiveRecord::Migration[8.1]
  def change
    add_column :tudla_accounting_tax_codes, :purchase_type, :integer
    add_check_constraint :tudla_accounting_tax_codes, "purchase_type = ANY (ARRAY[0, 1, 2])", name: "tudla_accounting_tax_codes_purchase_type_known"
  end
end
