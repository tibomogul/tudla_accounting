class AllowAccountCreditsInTudlaAccountingTaxReturnBoxParts < ActiveRecord::Migration[8.1]
  NAME = "tudla_accounting_tax_return_box_parts_one_source"

  def up
    remove_check_constraint :tudla_accounting_tax_return_box_parts, name: NAME
    add_check_constraint :tudla_accounting_tax_return_box_parts, one_source("source IN ('account', 'account_credits')"), name: NAME
  end

  def down
    remove_check_constraint :tudla_accounting_tax_return_box_parts, name: NAME
    add_check_constraint :tudla_accounting_tax_return_box_parts, one_source("source = 'account'"), name: NAME
  end

  private

  def one_source(account_sources)
    "(source LIKE 'tax_code_%' AND tax_code_id IS NOT NULL AND account_id IS NULL AND from_box_id IS NULL) OR " \
      "(#{account_sources} AND account_id IS NOT NULL AND tax_code_id IS NULL AND from_box_id IS NULL) OR " \
      "(source = 'box' AND from_box_id IS NOT NULL AND tax_code_id IS NULL AND account_id IS NULL)"
  end
end
