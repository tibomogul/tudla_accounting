# Who did what to an organization's books, and when. Rows are only ever added; on
# PostgreSQL a trigger refuses changes (see TudlaAccounting::DatabaseProtection).
class CreateTudlaAccountingAuditEvents < ActiveRecord::Migration[8.1]
  def up
    create_table :tudla_accounting_audit_events do |t|
      t.references :organization, polymorphic: true, null: false, index: false
      t.references :actor, polymorphic: true, index: false
      t.string :actor_label
      t.string :action, null: false
      t.references :subject, polymorphic: true, index: true
      t.string :subject_label
      t.jsonb :details, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_index :tudla_accounting_audit_events, %i[organization_type organization_id created_at], name: "index_tudla_accounting_audit_events_on_organization"

    TudlaAccounting::DatabaseProtection.install!(connection)
  end

  def down
    TudlaAccounting::DatabaseProtection.uninstall!(connection)
    drop_table :tudla_accounting_audit_events
    TudlaAccounting::DatabaseProtection.install!(connection)
  end
end
