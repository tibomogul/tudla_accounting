# Each email of a document, statement or payment to a customer or supplier: who it went
# to, what it said, and whether it was sent.
class CreateTudlaAccountingDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_deliveries do |t|
      t.references :organization, polymorphic: true, null: false, index: false
      t.references :subject, polymorphic: true, null: false, index: { name: "index_tudla_accounting_deliveries_on_subject" } # a document, payment or contact
      t.string :kind, null: false # document, reminder, statement, receipt or payment_notice
      t.integer :stage # a reminder's: which of the reminder_days it is for
      t.string :to, null: false
      t.string :cc
      t.string :subject_line, null: false
      t.text :message, null: false
      t.jsonb :details, null: false, default: {} # what else it needs (a statement's dates, say)
      t.string :status, null: false, default: "queued" # queued, sent or failed
      t.text :error
      t.string :requested_by
      t.datetime :sent_at
      t.timestamps
    end
    add_index :tudla_accounting_deliveries, %i[organization_type organization_id created_at], name: "index_tudla_accounting_deliveries_on_organization"
    add_check_constraint :tudla_accounting_deliveries, "kind IN ('document', 'reminder', 'statement', 'receipt', 'payment_notice')", name: "tudla_accounting_deliveries_kind_known"
    add_check_constraint :tudla_accounting_deliveries, "status IN ('queued', 'sent', 'failed')", name: "tudla_accounting_deliveries_status_known"
  end
end
