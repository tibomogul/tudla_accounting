# Sales invoices, supplier bills and the credit notes against them: drafted line by
# line, then approved, which numbers them and posts their entry.
class CreateTudlaAccountingDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_documents do |t|
      t.references :organization, polymorphic: true, null: false, index: false
      t.string :kind, null: false # sales_invoice, sales_credit, bill or supplier_credit
      t.string :status, null: false, default: "draft" # draft, approved or void
      t.references :contact, null: false, foreign_key: { to_table: :tudla_accounting_contacts }, index: { name: "index_tudla_accounting_documents_on_contact" }
      t.bigint :number # in the kind's own run, from approval
      t.string :number_label # as printed, kept if the format changes later
      t.string :reference # the customer's order number, or the supplier's own invoice number
      t.date :issued_on, null: false
      t.date :due_on
      t.boolean :tax_inclusive, null: false, default: false
      t.bigint :subtotal_cents, null: false, default: 0
      t.bigint :tax_cents, null: false, default: 0
      t.bigint :total_cents, null: false, default: 0
      t.references :credited_document, foreign_key: { to_table: :tudla_accounting_documents }, index: { name: "index_tudla_accounting_documents_on_credited" }
      t.references :entry, foreign_key: { to_table: :tudla_accounting_entries }, index: { name: "index_tudla_accounting_documents_on_entry", unique: true }
      t.text :notes
      t.datetime :approved_at
      t.date :voided_on
      t.string :void_reason
      t.timestamps
    end
    add_index :tudla_accounting_documents, %i[organization_type organization_id kind number], unique: true, where: "number IS NOT NULL",
              name: "tudla_accounting_documents_number_unique_key"
    add_index :tudla_accounting_documents, %i[organization_type organization_id issued_on], name: "index_tudla_accounting_documents_on_issued_on"
    add_check_constraint :tudla_accounting_documents, "kind IN ('sales_invoice', 'sales_credit', 'bill', 'supplier_credit')", name: "tudla_accounting_documents_kind_known"
    add_check_constraint :tudla_accounting_documents, "status IN ('draft', 'approved', 'void')", name: "tudla_accounting_documents_status_known"
    add_check_constraint :tudla_accounting_documents, "(status = 'draft') = (number IS NULL) AND (status = 'draft') = (entry_id IS NULL)",
                         name: "tudla_accounting_documents_numbered_when_approved"

    create_table :tudla_accounting_document_lines do |t|
      t.references :document, null: false, foreign_key: { to_table: :tudla_accounting_documents, on_delete: :cascade }, index: { name: "index_tudla_accounting_document_lines_on_document" }
      t.integer :position, null: false, default: 0
      t.string :description, null: false
      t.decimal :quantity, precision: 15, scale: 4, null: false, default: 1
      t.bigint :unit_price_cents, null: false, default: 0
      t.bigint :amount_cents, null: false, default: 0 # quantity times unit price, rounded to the cent
      t.references :account, null: false, foreign_key: { to_table: :tudla_accounting_accounts }, index: { name: "index_tudla_accounting_document_lines_on_account" }
      t.references :tax_code, foreign_key: { to_table: :tudla_accounting_tax_codes }, index: { name: "index_tudla_accounting_document_lines_on_tax_code" }
      t.bigint :tax_cents, null: false, default: 0
    end
    add_check_constraint :tudla_accounting_document_lines, "quantity >= 0 AND unit_price_cents >= 0 AND amount_cents >= 0",
                         name: "tudla_accounting_document_lines_not_negative"
  end
end
