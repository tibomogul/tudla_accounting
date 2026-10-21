# Tax return forms (a BAS, a VAT return): their boxes in order, each the sum of its
# parts: a tax code's net amount, tax or gross amount, an account's movement, or an
# earlier box, added or subtracted.
class CreateTudlaAccountingTaxReturns < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_tax_return_forms do |t|
      t.references :organization, polymorphic: true, null: false, index: false
      t.string :name, null: false
      t.timestamps
    end
    add_index :tudla_accounting_tax_return_forms, %i[organization_type organization_id name], unique: true, name: "index_tudla_accounting_tax_return_forms_on_name"

    create_table :tudla_accounting_tax_return_boxes do |t|
      t.references :form, null: false, foreign_key: { to_table: :tudla_accounting_tax_return_forms, on_delete: :cascade }, index: false
      t.integer :position, null: false
      t.string :label, null: false
      t.string :name, null: false
      t.boolean :whole_units, null: false, default: false # cents dropped, as the form asks
      t.timestamps
    end
    add_index :tudla_accounting_tax_return_boxes, %i[form_id label], unique: true, name: "index_tudla_accounting_tax_return_boxes_on_label"

    create_table :tudla_accounting_tax_return_box_parts do |t|
      t.references :box, null: false, foreign_key: { to_table: :tudla_accounting_tax_return_boxes, on_delete: :cascade }, index: { name: "index_tudla_accounting_tax_return_box_parts_on_box" }
      t.string :source, null: false # tax_code_base, tax_code_tax, tax_code_gross, account or box
      t.integer :sign, null: false, default: 1
      t.references :tax_code, foreign_key: { to_table: :tudla_accounting_tax_codes }, index: { name: "index_tudla_accounting_tax_return_box_parts_on_tax_code" }
      t.references :account, foreign_key: { to_table: :tudla_accounting_accounts }, index: { name: "index_tudla_accounting_tax_return_box_parts_on_account" }
      # Cascades so deleting a form can take its boxes in any order; TaxReturnBox refuses to
      # delete a box another one uses.
      t.references :from_box, foreign_key: { to_table: :tudla_accounting_tax_return_boxes, on_delete: :cascade }, index: { name: "index_tudla_accounting_tax_return_box_parts_on_from_box" }
    end
    add_check_constraint :tudla_accounting_tax_return_box_parts, "sign IN (1, -1)", name: "tudla_accounting_tax_return_box_parts_sign"
    add_check_constraint :tudla_accounting_tax_return_box_parts,
                         "(source LIKE 'tax_code_%' AND tax_code_id IS NOT NULL AND account_id IS NULL AND from_box_id IS NULL) OR " \
                         "(source = 'account' AND account_id IS NOT NULL AND tax_code_id IS NULL AND from_box_id IS NULL) OR " \
                         "(source = 'box' AND from_box_id IS NOT NULL AND tax_code_id IS NULL AND account_id IS NULL)",
                         name: "tudla_accounting_tax_return_box_parts_one_source"
  end
end
