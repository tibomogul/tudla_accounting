# The tax withheld from a supplier on a bill or supplier credit, line by line. Approving
# it posts the tax and keeps a WithheldTax row, in the organization's currency, for the
# reports; reversing it adds an opposite row.
class AddWithholdingToTudlaAccountingDocuments < ActiveRecord::Migration[8.1]
  def change
    add_reference :tudla_accounting_document_lines, :withholding_code, foreign_key: { to_table: :tudla_accounting_withholding_codes },
                                                                       index: { name: "index_tudla_accounting_document_lines_on_withholding_code" }
    add_column :tudla_accounting_document_lines, :withheld_cents, :bigint, null: false, default: 0
    add_check_constraint :tudla_accounting_document_lines, "withheld_cents >= 0", name: "tudla_accounting_document_lines_withheld_not_negative"
    add_column :tudla_accounting_documents, :withheld_cents, :bigint, null: false, default: 0
    add_check_constraint :tudla_accounting_documents, "withheld_cents >= 0", name: "tudla_accounting_documents_withheld_not_negative"

    create_table :tudla_accounting_withheld_taxes do |t|
      t.references :organization, polymorphic: true, null: false, index: false
      t.references :contact, null: false, foreign_key: { to_table: :tudla_accounting_contacts }, index: { name: "index_tudla_accounting_withheld_taxes_on_contact" }
      t.references :withholding_code, null: false, foreign_key: { to_table: :tudla_accounting_withholding_codes }, index: { name: "index_tudla_accounting_withheld_taxes_on_withholding_code" }
      t.references :entry, null: false, foreign_key: { to_table: :tudla_accounting_entries }, index: { name: "index_tudla_accounting_withheld_taxes_on_entry" }
      t.references :document_line, foreign_key: { to_table: :tudla_accounting_document_lines }, index: { name: "index_tudla_accounting_withheld_taxes_on_document_line" }
      t.string :direction, null: false
      t.date :on, null: false
      t.bigint :base_cents, null: false
      t.bigint :withheld_cents, null: false
      t.boolean :reversal, null: false, default: false
      t.datetime :created_at, null: false
      t.index %w[organization_type organization_id direction on], name: "index_tudla_accounting_withheld_taxes_on_organization_and_date"
      t.check_constraint "direction::text = ANY (ARRAY['from_supplier'::character varying::text, 'by_customer'::character varying::text])", name: "tudla_accounting_withheld_taxes_direction_known"
    end
  end
end
