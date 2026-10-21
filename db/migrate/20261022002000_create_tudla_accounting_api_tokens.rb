# Tokens other systems use to reach an organization's books through the JSON API. Only a
# digest of each is kept; the token itself is shown once, when it is made.
class CreateTudlaAccountingApiTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_api_tokens do |t|
      t.references :organization, polymorphic: true, null: false, index: { name: "index_tudla_accounting_api_tokens_on_organization" }
      t.string :name, null: false
      t.string :token_digest, null: false
      t.string :hint, null: false # the token's first characters, to tell tokens apart
      t.string :permissions, array: true, null: false, default: []
      t.date :expires_on
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.string :created_by
      t.string :revoked_by
      t.timestamps
    end
    add_index :tudla_accounting_api_tokens, :token_digest, unique: true, name: "tudla_accounting_api_tokens_digest_unique_key"
    add_check_constraint :tudla_accounting_api_tokens, "permissions <@ ARRAY['read', 'record', 'post', 'administer']::varchar[] AND cardinality(permissions) > 0",
                         name: "tudla_accounting_api_tokens_permissions_known"
  end
end
