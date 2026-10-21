# Tax returns as they were filed: a form's figures for a run of months on a basis,
# kept as filed so later changes to the books can be shown against them. A filed return
# can be withdrawn (with a reason) so a corrected one can be filed for the same months.
class CreateTudlaAccountingFiledTaxReturns < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_filed_tax_returns do |t|
      t.references :organization, polymorphic: true, null: false, index: false
      t.references :form, null: false, foreign_key: { to_table: :tudla_accounting_tax_return_forms }, index: { name: "index_tudla_accounting_filed_tax_returns_on_form" }
      t.datetime :from_date, null: false
      t.datetime :thru_date, null: false
      t.string :basis, null: false
      t.jsonb :figures, null: false, default: [] # [{ "label", "name", "cents" }] in the form's order
      t.datetime :filed_at, null: false
      t.string :filed_by
      t.datetime :withdrawn_at
      t.string :withdrawn_by
      t.text :withdrawn_reason
      t.timestamps
    end
    add_index :tudla_accounting_filed_tax_returns, %i[organization_type organization_id filed_at], name: "index_tudla_accounting_filed_tax_returns_on_organization"
  end
end
