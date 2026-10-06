# Tax codes (GST, VAT, sales tax...) and the tax tags on entry lines: a line taxed under a
# code is its base, and the tax on it is a line of its own on the code's account.
class CreateTudlaAccountingTaxCodes < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_tax_codes do |t|
      t.references :organization, polymorphic: true, null: false, index: false
      t.string :code, null: false
      t.string :name, null: false
      t.decimal :rate, precision: 9, scale: 6, null: false, default: 0
      t.integer :kind, null: false
      t.references :account, foreign_key: { to_table: :tudla_accounting_accounts }
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :tudla_accounting_tax_codes, %i[organization_type organization_id code], unique: true, name: "tudla_accounting_tax_codes_unique_key"
    add_check_constraint :tudla_accounting_tax_codes, "kind IN (0, 1)", name: "tudla_accounting_tax_codes_kind_known"
    add_check_constraint :tudla_accounting_tax_codes, "rate >= 0", name: "tudla_accounting_tax_codes_rate_not_negative"

    add_reference :tudla_accounting_details, :tax_code, foreign_key: { to_table: :tudla_accounting_tax_codes }
    add_column :tudla_accounting_details, :tax_role, :integer
    add_check_constraint :tudla_accounting_details, "(tax_code_id IS NULL) = (tax_role IS NULL) AND (tax_role IS NULL OR tax_role IN (0, 1))",
                         name: "tudla_accounting_details_tax_tagged"
  end
end
