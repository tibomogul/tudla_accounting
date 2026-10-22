# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_22_006000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "organizations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency"
    t.string "name"
    t.datetime "updated_at", null: false
  end

  create_table "tudla_accounting_accounts", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "ancestry", default: "/", null: false
    t.integer "ancestry_depth", default: 0, null: false
    t.integer "cash_flow_activity"
    t.integer "category", null: false
    t.string "code", null: false
    t.bigint "contra_account_id"
    t.datetime "created_at", null: false
    t.string "currency"
    t.string "name", null: false
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.string "role"
    t.datetime "updated_at", null: false
    t.index ["ancestry"], name: "index_tudla_accounting_accounts_on_ancestry"
    t.index ["category"], name: "index_tudla_accounting_accounts_on_category"
    t.index ["code"], name: "index_tudla_accounting_accounts_on_code"
    t.index ["contra_account_id"], name: "index_tudla_accounting_accounts_on_contra_account_id"
    t.index ["name"], name: "index_tudla_accounting_accounts_on_name"
    t.index ["organization_type", "organization_id", "code"], name: "tudla_accounting_accounts_unique_key", unique: true
    t.index ["organization_type", "organization_id", "role"], name: "index_tudla_accounting_accounts_on_organization_and_role", unique: true, where: "(role IS NOT NULL)"
    t.index ["organization_type", "organization_id"], name: "index_tudla_accounting_accounts_on_organization"
    t.check_constraint "cash_flow_activity IS NULL OR (cash_flow_activity = ANY (ARRAY[0, 1, 2]))", name: "tudla_accounting_accounts_cash_flow_activity_known"
    t.check_constraint "category = ANY (ARRAY[0, 1, 2, 3, 4])", name: "tudla_accounting_accounts_category_known"
    t.check_constraint "role::text = ANY (ARRAY['receivable'::character varying::text, 'payable'::character varying::text, 'retained_earnings'::character varying::text, 'unrealized_fx_gain'::character varying::text, 'realized_fx_gain'::character varying::text])", name: "tudla_accounting_accounts_role_known"
  end

  create_table "tudla_accounting_allocations", force: :cascade do |t|
    t.datetime "allocated_at", null: false
    t.bigint "amount_cents", null: false
    t.datetime "created_at", null: false
    t.bigint "from_id", null: false
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.bigint "other_currency_cents"
    t.bigint "realized_entry_id"
    t.datetime "reversed_at"
    t.bigint "to_id", null: false
    t.datetime "updated_at", null: false
    t.index ["from_id"], name: "index_tudla_accounting_allocations_on_from_id"
    t.index ["organization_type", "organization_id"], name: "index_tudla_accounting_allocations_on_organization"
    t.index ["realized_entry_id"], name: "index_tudla_accounting_allocations_on_realized_entry_id"
    t.index ["to_id"], name: "index_tudla_accounting_allocations_on_to_id"
    t.check_constraint "amount_cents > 0", name: "tudla_accounting_allocations_amount_positive"
  end

  create_table "tudla_accounting_api_tokens", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "created_by"
    t.date "expires_on"
    t.string "hint", null: false
    t.datetime "last_used_at"
    t.string "name", null: false
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.string "permissions", default: [], null: false, array: true
    t.datetime "revoked_at"
    t.string "revoked_by"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_type", "organization_id"], name: "index_tudla_accounting_api_tokens_on_organization"
    t.index ["token_digest"], name: "tudla_accounting_api_tokens_digest_unique_key", unique: true
    t.check_constraint "permissions <@ ARRAY['read'::character varying, 'record'::character varying, 'post'::character varying, 'administer'::character varying] AND cardinality(permissions) > 0", name: "tudla_accounting_api_tokens_permissions_known"
  end

  create_table "tudla_accounting_audit_events", force: :cascade do |t|
    t.string "action", null: false
    t.bigint "actor_id"
    t.string "actor_label"
    t.string "actor_type"
    t.datetime "created_at", null: false
    t.jsonb "details", default: {}, null: false
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.bigint "subject_id"
    t.string "subject_label"
    t.string "subject_type"
    t.index ["organization_type", "organization_id", "created_at"], name: "index_tudla_accounting_audit_events_on_organization"
    t.index ["subject_type", "subject_id"], name: "index_tudla_accounting_audit_events_on_subject"
  end

  create_table "tudla_accounting_balances", force: :cascade do |t|
    t.bigint "account_id"
    t.datetime "created_at", null: false
    t.string "currency"
    t.bigint "current_amount_cents"
    t.bigint "ending_amount_cents"
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.bigint "period_id"
    t.bigint "starting_amount_cents"
    t.datetime "updated_at", null: false
    t.index ["account_id", "period_id"], name: "tudla_accounting_balances_unique_key", unique: true
    t.index ["account_id"], name: "index_tudla_accounting_balances_on_account_id"
    t.index ["organization_type", "organization_id"], name: "index_tudla_accounting_balances_on_organization"
    t.index ["period_id"], name: "index_tudla_accounting_balances_on_period_id"
  end

  create_table "tudla_accounting_bank_account_balances", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "balance_cents"
    t.datetime "created_at", null: false
    t.string "currency"
    t.string "name"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "tudla_accounting_bank_account_balances_unique_key", unique: true
  end

  create_table "tudla_accounting_bank_matches", force: :cascade do |t|
    t.bigint "bank_statement_line_id", null: false
    t.datetime "created_at", null: false
    t.bigint "detail_id", null: false
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.datetime "updated_at", null: false
    t.index ["bank_statement_line_id"], name: "index_tudla_accounting_bank_matches_on_bank_statement_line_id"
    t.index ["detail_id"], name: "index_tudla_accounting_bank_matches_on_detail_id", unique: true
  end

  create_table "tudla_accounting_bank_rules", force: :cascade do |t|
    t.bigint "account_id"
    t.boolean "active", default: true, null: false
    t.bigint "amount_max_cents"
    t.bigint "amount_min_cents"
    t.bigint "counter_account_id", null: false
    t.datetime "created_at", null: false
    t.string "description_contains", null: false
    t.bigint "dimension_value_ids", default: [], null: false, array: true
    t.string "direction"
    t.string "name", null: false
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.string "particulars"
    t.integer "position", default: 0, null: false
    t.bigint "tax_code_id"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_tudla_accounting_bank_rules_on_account"
    t.index ["counter_account_id"], name: "index_tudla_accounting_bank_rules_on_counter_account"
    t.index ["organization_type", "organization_id"], name: "index_tudla_accounting_bank_rules_on_organization"
    t.index ["tax_code_id"], name: "index_tudla_accounting_bank_rules_on_tax_code"
    t.check_constraint "direction IS NULL OR (direction::text = ANY (ARRAY['in'::character varying::text, 'out'::character varying::text]))", name: "tudla_accounting_bank_rules_direction_known"
  end

  create_table "tudla_accounting_bank_statement_lines", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "amount_cents", null: false
    t.bigint "balance_cents"
    t.datetime "created_at", null: false
    t.string "currency", null: false
    t.string "description", null: false
    t.string "external_id", null: false
    t.date "occurred_on", null: false
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.string "reference"
    t.datetime "updated_at", null: false
    t.index ["account_id", "external_id"], name: "tudla_accounting_bank_statement_lines_unique_key", unique: true
    t.index ["account_id", "occurred_on"], name: "idx_on_account_id_occurred_on_9c70487287"
    t.check_constraint "amount_cents <> 0", name: "tudla_accounting_bank_statement_lines_amount_not_zero"
  end

  create_table "tudla_accounting_budget_lines", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "amount_cents", null: false
    t.bigint "budget_id", null: false
    t.bigint "period_id", null: false
    t.index ["account_id"], name: "index_tudla_accounting_budget_lines_on_account"
    t.index ["budget_id", "account_id", "period_id"], name: "index_tudla_accounting_budget_lines_unique", unique: true
    t.index ["period_id"], name: "index_tudla_accounting_budget_lines_on_period"
  end

  create_table "tudla_accounting_budgets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "main", default: false, null: false
    t.string "name", null: false
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.bigint "period_id", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_type", "organization_id", "period_id", "name"], name: "index_tudla_accounting_budgets_on_name", unique: true
    t.index ["organization_type", "organization_id", "period_id"], name: "index_tudla_accounting_budgets_one_main", unique: true, where: "main"
    t.index ["period_id"], name: "index_tudla_accounting_budgets_on_period"
  end

  create_table "tudla_accounting_carrying_amount_forexes", force: :cascade do |t|
    t.bigint "carrying_amount_id", null: false
    t.date "conversion_date"
    t.datetime "created_at", null: false
    t.string "other_currency", limit: 3, default: "XXX", null: false
    t.bigint "other_currency_amount_cents", default: 0, null: false
    t.decimal "transaction_rate", precision: 24, scale: 8
    t.datetime "updated_at", null: false
    t.index ["carrying_amount_id"], name: "idx_on_carrying_amount_id_03cbd631ae", unique: true
  end

  create_table "tudla_accounting_carrying_amounts", force: :cascade do |t|
    t.bigint "amount_cents"
    t.integer "carrying_amount_type"
    t.datetime "created_at", null: false
    t.bigint "detail_id", null: false
    t.datetime "due_date"
    t.bigint "related_party_id", null: false
    t.string "related_party_type", null: false
    t.datetime "updated_at", null: false
    t.index ["detail_id"], name: "tudla_accounting_carrying_amounts_unique_key", unique: true
    t.index ["related_party_type", "related_party_id"], name: "index_tudla_accounting_carrying_amounts_on_related_party"
    t.check_constraint "carrying_amount_type = ANY (ARRAY[0, 1])", name: "tudla_accounting_carrying_amounts_type_known"
  end

  create_table "tudla_accounting_contacts", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.text "address"
    t.datetime "created_at", null: false
    t.bigint "default_account_id"
    t.bigint "default_tax_code_id"
    t.string "email"
    t.string "kind", default: "customer", null: false
    t.string "name", null: false
    t.text "notes"
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.integer "payment_terms_days"
    t.string "phone"
    t.string "tax_number"
    t.datetime "updated_at", null: false
    t.index ["default_account_id"], name: "index_tudla_accounting_contacts_on_default_account"
    t.index ["default_tax_code_id"], name: "index_tudla_accounting_contacts_on_default_tax_code"
    t.index ["organization_type", "organization_id", "name"], name: "index_tudla_accounting_contacts_on_name"
    t.check_constraint "kind::text = ANY (ARRAY['customer'::character varying::text, 'supplier'::character varying::text, 'both'::character varying::text])", name: "tudla_accounting_contacts_kind_known"
    t.check_constraint "payment_terms_days IS NULL OR payment_terms_days >= 0", name: "tudla_accounting_contacts_terms_not_negative"
  end

  create_table "tudla_accounting_deliveries", force: :cascade do |t|
    t.string "cc"
    t.datetime "created_at", null: false
    t.jsonb "details", default: {}, null: false
    t.text "error"
    t.string "kind", null: false
    t.text "message", null: false
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.string "requested_by"
    t.datetime "sent_at"
    t.integer "stage"
    t.string "status", default: "queued", null: false
    t.bigint "subject_id", null: false
    t.string "subject_line", null: false
    t.string "subject_type", null: false
    t.string "to", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_type", "organization_id", "created_at"], name: "index_tudla_accounting_deliveries_on_organization"
    t.index ["subject_type", "subject_id"], name: "index_tudla_accounting_deliveries_on_subject"
    t.check_constraint "kind::text = ANY (ARRAY['document'::character varying::text, 'reminder'::character varying::text, 'statement'::character varying::text, 'receipt'::character varying::text, 'payment_notice'::character varying::text])", name: "tudla_accounting_deliveries_kind_known"
    t.check_constraint "status::text = ANY (ARRAY['queued'::character varying::text, 'sent'::character varying::text, 'failed'::character varying::text])", name: "tudla_accounting_deliveries_status_known"
  end

  create_table "tudla_accounting_detail_tags", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "detail_id", null: false
    t.bigint "dimension_id", null: false
    t.bigint "dimension_value_id", null: false
    t.datetime "updated_at", null: false
    t.index ["detail_id", "dimension_id"], name: "tudla_accounting_detail_tags_unique_key", unique: true
    t.index ["dimension_id"], name: "index_tudla_accounting_detail_tags_on_dimension_id"
    t.index ["dimension_value_id"], name: "index_tudla_accounting_detail_tags_on_dimension_value_id"
  end

  create_table "tudla_accounting_details", force: :cascade do |t|
    t.bigint "account_id"
    t.bigint "amount_cents"
    t.bigint "balance_id"
    t.datetime "created_at", null: false
    t.string "currency"
    t.string "description"
    t.bigint "entry_id"
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.integer "tally"
    t.bigint "tax_code_id"
    t.integer "tax_role"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_tudla_accounting_details_on_account_id"
    t.index ["balance_id"], name: "index_tudla_accounting_details_on_balance_id"
    t.index ["entry_id"], name: "index_tudla_accounting_details_on_entry_id"
    t.index ["organization_type", "organization_id"], name: "index_tudla_accounting_details_on_organization"
    t.index ["tax_code_id"], name: "index_tudla_accounting_details_on_tax_code_id"
    t.check_constraint "(tax_code_id IS NULL) = (tax_role IS NULL) AND (tax_role IS NULL OR (tax_role = ANY (ARRAY[0, 1])))", name: "tudla_accounting_details_tax_tagged"
    t.check_constraint "amount_cents > 0", name: "tudla_accounting_details_amount_positive"
    t.check_constraint "tally = ANY (ARRAY[0, 1])", name: "tudla_accounting_details_tally_known"
  end

  create_table "tudla_accounting_dimension_values", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.bigint "dimension_id", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["dimension_id", "code"], name: "tudla_accounting_dimension_values_unique_key", unique: true
  end

  create_table "tudla_accounting_dimensions", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_type", "organization_id", "code"], name: "tudla_accounting_dimensions_unique_key", unique: true
  end

  create_table "tudla_accounting_document_lines", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "amount_cents", default: 0, null: false
    t.string "description", null: false
    t.bigint "dimension_value_ids", default: [], null: false, array: true
    t.bigint "document_id", null: false
    t.integer "position", default: 0, null: false
    t.decimal "quantity", precision: 15, scale: 4, default: "1.0", null: false
    t.bigint "tax_cents", default: 0, null: false
    t.bigint "tax_code_id"
    t.bigint "unit_price_cents", default: 0, null: false
    t.index ["account_id"], name: "index_tudla_accounting_document_lines_on_account"
    t.index ["document_id"], name: "index_tudla_accounting_document_lines_on_document"
    t.index ["tax_code_id"], name: "index_tudla_accounting_document_lines_on_tax_code"
    t.check_constraint "quantity >= 0::numeric AND unit_price_cents >= 0 AND amount_cents >= 0", name: "tudla_accounting_document_lines_not_negative"
  end

  create_table "tudla_accounting_documents", force: :cascade do |t|
    t.datetime "approved_at"
    t.bigint "contact_id", null: false
    t.datetime "created_at", null: false
    t.bigint "credited_document_id"
    t.date "due_on"
    t.bigint "entry_id"
    t.string "idempotency_key"
    t.date "issued_on", null: false
    t.string "kind", null: false
    t.text "notes"
    t.bigint "number"
    t.string "number_label"
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.string "reference"
    t.string "status", default: "draft", null: false
    t.bigint "subtotal_cents", default: 0, null: false
    t.bigint "tax_cents", default: 0, null: false
    t.boolean "tax_inclusive", default: false, null: false
    t.bigint "total_cents", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "void_reason"
    t.date "voided_on"
    t.index ["contact_id"], name: "index_tudla_accounting_documents_on_contact"
    t.index ["credited_document_id"], name: "index_tudla_accounting_documents_on_credited"
    t.index ["entry_id"], name: "index_tudla_accounting_documents_on_entry", unique: true
    t.index ["organization_type", "organization_id", "idempotency_key"], name: "tudla_accounting_documents_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["organization_type", "organization_id", "issued_on"], name: "index_tudla_accounting_documents_on_issued_on"
    t.index ["organization_type", "organization_id", "kind", "number"], name: "tudla_accounting_documents_number_unique_key", unique: true, where: "(number IS NOT NULL)"
    t.check_constraint "(status::text = 'draft'::text) = (number IS NULL) AND (status::text = 'draft'::text) = (entry_id IS NULL)", name: "tudla_accounting_documents_numbered_when_approved"
    t.check_constraint "kind::text = ANY (ARRAY['sales_invoice'::character varying::text, 'sales_credit'::character varying::text, 'bill'::character varying::text, 'supplier_credit'::character varying::text])", name: "tudla_accounting_documents_kind_known"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying::text, 'approved'::character varying::text, 'void'::character varying::text])", name: "tudla_accounting_documents_status_known"
  end

  create_table "tudla_accounting_entries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "idempotency_key"
    t.bigint "number"
    t.string "number_series", default: "", null: false
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.text "particulars"
    t.datetime "posted_at"
    t.string "reference"
    t.bigint "related_id"
    t.string "related_type"
    t.date "reverse_on"
    t.bigint "source_id"
    t.string "source_type"
    t.datetime "transacted_at"
    t.datetime "updated_at", null: false
    t.index ["organization_type", "organization_id", "idempotency_key"], name: "tudla_accounting_entries_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["organization_type", "organization_id", "number_series", "number"], name: "tudla_accounting_entries_number_unique_key", unique: true, where: "(number IS NOT NULL)"
    t.index ["organization_type", "organization_id"], name: "index_tudla_accounting_entries_on_organization"
    t.index ["posted_at"], name: "index_tudla_accounting_entries_on_posted_at"
    t.index ["related_type", "related_id"], name: "index_tudla_accounting_entries_on_related"
    t.index ["source_type", "source_id"], name: "index_tudla_accounting_entries_on_source"
    t.index ["transacted_at"], name: "index_tudla_accounting_entries_on_transacted_at"
    t.check_constraint "(posted_at IS NULL) = (number IS NULL)", name: "tudla_accounting_entries_numbered_when_posted"
  end

  create_table "tudla_accounting_filed_tax_returns", force: :cascade do |t|
    t.string "basis", null: false
    t.datetime "created_at", null: false
    t.jsonb "figures", default: [], null: false
    t.datetime "filed_at", null: false
    t.string "filed_by"
    t.bigint "form_id", null: false
    t.datetime "from_date", null: false
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.datetime "thru_date", null: false
    t.datetime "updated_at", null: false
    t.datetime "withdrawn_at"
    t.string "withdrawn_by"
    t.text "withdrawn_reason"
    t.index ["form_id"], name: "index_tudla_accounting_filed_tax_returns_on_form"
    t.index ["organization_type", "organization_id", "filed_at"], name: "index_tudla_accounting_filed_tax_returns_on_organization"
  end

  create_table "tudla_accounting_foreign_exchanges", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "detail_id", null: false
    t.string "other_currency"
    t.bigint "other_currency_cents"
    t.decimal "rate", precision: 24, scale: 8
    t.datetime "updated_at", null: false
    t.index ["detail_id"], name: "tudla_accounting_foreign_exchanges_unique_key", unique: true
  end

  create_table "tudla_accounting_forex_rates", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "day"
    t.string "from"
    t.integer "month"
    t.decimal "rate", precision: 24, scale: 8
    t.string "to"
    t.datetime "updated_at", null: false
    t.integer "year"
    t.index ["from", "to", "year", "month", "day"], name: "tudla_accounting_forex_rates_unique_key", unique: true
  end

  create_table "tudla_accounting_payments", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "amount_cents", null: false
    t.bigint "contact_id", null: false
    t.datetime "created_at", null: false
    t.bigint "entry_id"
    t.string "idempotency_key"
    t.string "kind", null: false
    t.text "notes"
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.date "paid_on", null: false
    t.string "reference"
    t.string "status", default: "posted", null: false
    t.datetime "updated_at", null: false
    t.string "void_reason"
    t.date "voided_on"
    t.index ["account_id"], name: "index_tudla_accounting_payments_on_account"
    t.index ["contact_id"], name: "index_tudla_accounting_payments_on_contact"
    t.index ["entry_id"], name: "index_tudla_accounting_payments_on_entry", unique: true
    t.index ["organization_type", "organization_id", "idempotency_key"], name: "tudla_accounting_payments_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["organization_type", "organization_id", "paid_on"], name: "index_tudla_accounting_payments_on_paid_on"
    t.check_constraint "amount_cents > 0", name: "tudla_accounting_payments_amount_positive"
    t.check_constraint "kind::text = ANY (ARRAY['received'::character varying, 'paid'::character varying, 'refund'::character varying, 'supplier_refund'::character varying]::text[])", name: "tudla_accounting_payments_kind_known"
    t.check_constraint "status::text = ANY (ARRAY['posted'::character varying::text, 'void'::character varying::text])", name: "tudla_accounting_payments_status_known"
  end

  create_table "tudla_accounting_periods", force: :cascade do |t|
    t.string "ancestry", default: "/", null: false
    t.integer "ancestry_depth", default: 0, null: false
    t.integer "children_count", default: 0, null: false
    t.datetime "closed_at"
    t.datetime "created_at", null: false
    t.datetime "from_date", null: false
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.datetime "thru_date", null: false
    t.datetime "updated_at", null: false
    t.index ["ancestry"], name: "index_tudla_accounting_periods_on_ancestry"
    t.index ["organization_type", "organization_id"], name: "index_tudla_accounting_periods_on_organization"
  end

  create_table "tudla_accounting_recurring_entries", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.integer "day_of_month"
    t.date "ends_on"
    t.string "frequency", null: false
    t.integer "interval", default: 1, null: false
    t.string "last_problem"
    t.string "name", null: false
    t.date "next_on"
    t.integer "occurrences_count", default: 0, null: false
    t.integer "occurrences_limit"
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.text "particulars", null: false
    t.boolean "post_automatically", default: false, null: false
    t.string "reference"
    t.boolean "reverse_next_month", default: false, null: false
    t.date "starts_on", null: false
    t.boolean "tax_inclusive", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["active", "next_on"], name: "index_tudla_accounting_recurring_entries_on_active_and_next_on"
    t.index ["organization_type", "organization_id"], name: "index_tudla_accounting_recurring_entries_on_organization"
    t.check_constraint "\"interval\" > 0", name: "tudla_accounting_recurring_entries_interval_positive"
    t.check_constraint "frequency::text = ANY (ARRAY['weekly'::character varying::text, 'monthly'::character varying::text, 'yearly'::character varying::text])", name: "tudla_accounting_recurring_entries_frequency_known"
  end

  create_table "tudla_accounting_recurring_entry_lines", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "amount_cents", null: false
    t.datetime "created_at", null: false
    t.string "description"
    t.bigint "dimension_value_ids", default: [], null: false, array: true
    t.bigint "recurring_entry_id", null: false
    t.integer "tally", null: false
    t.bigint "tax_code_id"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_tudla_accounting_recurring_entry_lines_on_account"
    t.index ["recurring_entry_id"], name: "index_tudla_accounting_recurring_entry_lines_on_recurring_entry"
    t.index ["tax_code_id"], name: "index_tudla_accounting_recurring_entry_lines_on_tax_code"
    t.check_constraint "amount_cents > 0", name: "tudla_accounting_recurring_entry_lines_amount_positive"
  end

  create_table "tudla_accounting_sequences", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "last_value", null: false
    t.string "name", null: false
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_type", "organization_id", "name"], name: "tudla_accounting_sequences_unique_key", unique: true
  end

  create_table "tudla_accounting_tax_codes", force: :cascade do |t|
    t.bigint "account_id"
    t.boolean "active", default: true, null: false
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.integer "kind", null: false
    t.string "name", null: false
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.decimal "rate", precision: 9, scale: 6, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_tudla_accounting_tax_codes_on_account_id"
    t.index ["organization_type", "organization_id", "code"], name: "tudla_accounting_tax_codes_unique_key", unique: true
    t.check_constraint "kind = ANY (ARRAY[0, 1])", name: "tudla_accounting_tax_codes_kind_known"
    t.check_constraint "rate >= 0::numeric", name: "tudla_accounting_tax_codes_rate_not_negative"
  end

  create_table "tudla_accounting_tax_return_box_parts", force: :cascade do |t|
    t.bigint "account_id"
    t.bigint "box_id", null: false
    t.bigint "from_box_id"
    t.integer "sign", default: 1, null: false
    t.string "source", null: false
    t.bigint "tax_code_id"
    t.index ["account_id"], name: "index_tudla_accounting_tax_return_box_parts_on_account"
    t.index ["box_id"], name: "index_tudla_accounting_tax_return_box_parts_on_box"
    t.index ["from_box_id"], name: "index_tudla_accounting_tax_return_box_parts_on_from_box"
    t.index ["tax_code_id"], name: "index_tudla_accounting_tax_return_box_parts_on_tax_code"
    t.check_constraint "sign = ANY (ARRAY[1, '-1'::integer])", name: "tudla_accounting_tax_return_box_parts_sign"
    t.check_constraint "source::text ~~ 'tax_code_%'::text AND tax_code_id IS NOT NULL AND account_id IS NULL AND from_box_id IS NULL OR source::text = 'account'::text AND account_id IS NOT NULL AND tax_code_id IS NULL AND from_box_id IS NULL OR source::text = 'box'::text AND from_box_id IS NOT NULL AND tax_code_id IS NULL AND account_id IS NULL", name: "tudla_accounting_tax_return_box_parts_one_source"
  end

  create_table "tudla_accounting_tax_return_boxes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "form_id", null: false
    t.string "label", null: false
    t.string "name", null: false
    t.integer "position", null: false
    t.datetime "updated_at", null: false
    t.boolean "whole_units", default: false, null: false
    t.index ["form_id", "label"], name: "index_tudla_accounting_tax_return_boxes_on_label", unique: true
  end

  create_table "tudla_accounting_tax_return_forms", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_type", "organization_id", "name"], name: "index_tudla_accounting_tax_return_forms_on_name", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "tudla_accounting_accounts", "tudla_accounting_accounts", column: "contra_account_id"
  add_foreign_key "tudla_accounting_allocations", "tudla_accounting_carrying_amounts", column: "from_id"
  add_foreign_key "tudla_accounting_allocations", "tudla_accounting_carrying_amounts", column: "to_id"
  add_foreign_key "tudla_accounting_allocations", "tudla_accounting_entries", column: "realized_entry_id"
  add_foreign_key "tudla_accounting_balances", "tudla_accounting_accounts", column: "account_id"
  add_foreign_key "tudla_accounting_balances", "tudla_accounting_periods", column: "period_id"
  add_foreign_key "tudla_accounting_bank_account_balances", "tudla_accounting_accounts", column: "account_id"
  add_foreign_key "tudla_accounting_bank_matches", "tudla_accounting_bank_statement_lines", column: "bank_statement_line_id"
  add_foreign_key "tudla_accounting_bank_matches", "tudla_accounting_details", column: "detail_id"
  add_foreign_key "tudla_accounting_bank_rules", "tudla_accounting_accounts", column: "account_id"
  add_foreign_key "tudla_accounting_bank_rules", "tudla_accounting_accounts", column: "counter_account_id"
  add_foreign_key "tudla_accounting_bank_rules", "tudla_accounting_tax_codes", column: "tax_code_id"
  add_foreign_key "tudla_accounting_bank_statement_lines", "tudla_accounting_accounts", column: "account_id"
  add_foreign_key "tudla_accounting_budget_lines", "tudla_accounting_accounts", column: "account_id"
  add_foreign_key "tudla_accounting_budget_lines", "tudla_accounting_budgets", column: "budget_id", on_delete: :cascade
  add_foreign_key "tudla_accounting_budget_lines", "tudla_accounting_periods", column: "period_id"
  add_foreign_key "tudla_accounting_budgets", "tudla_accounting_periods", column: "period_id"
  add_foreign_key "tudla_accounting_carrying_amount_forexes", "tudla_accounting_carrying_amounts", column: "carrying_amount_id"
  add_foreign_key "tudla_accounting_carrying_amounts", "tudla_accounting_details", column: "detail_id"
  add_foreign_key "tudla_accounting_contacts", "tudla_accounting_accounts", column: "default_account_id"
  add_foreign_key "tudla_accounting_contacts", "tudla_accounting_tax_codes", column: "default_tax_code_id"
  add_foreign_key "tudla_accounting_detail_tags", "tudla_accounting_details", column: "detail_id"
  add_foreign_key "tudla_accounting_detail_tags", "tudla_accounting_dimension_values", column: "dimension_value_id"
  add_foreign_key "tudla_accounting_detail_tags", "tudla_accounting_dimensions", column: "dimension_id"
  add_foreign_key "tudla_accounting_details", "tudla_accounting_accounts", column: "account_id"
  add_foreign_key "tudla_accounting_details", "tudla_accounting_balances", column: "balance_id"
  add_foreign_key "tudla_accounting_details", "tudla_accounting_entries", column: "entry_id"
  add_foreign_key "tudla_accounting_details", "tudla_accounting_tax_codes", column: "tax_code_id"
  add_foreign_key "tudla_accounting_dimension_values", "tudla_accounting_dimensions", column: "dimension_id"
  add_foreign_key "tudla_accounting_document_lines", "tudla_accounting_accounts", column: "account_id"
  add_foreign_key "tudla_accounting_document_lines", "tudla_accounting_documents", column: "document_id", on_delete: :cascade
  add_foreign_key "tudla_accounting_document_lines", "tudla_accounting_tax_codes", column: "tax_code_id"
  add_foreign_key "tudla_accounting_documents", "tudla_accounting_contacts", column: "contact_id"
  add_foreign_key "tudla_accounting_documents", "tudla_accounting_documents", column: "credited_document_id"
  add_foreign_key "tudla_accounting_documents", "tudla_accounting_entries", column: "entry_id"
  add_foreign_key "tudla_accounting_filed_tax_returns", "tudla_accounting_tax_return_forms", column: "form_id"
  add_foreign_key "tudla_accounting_foreign_exchanges", "tudla_accounting_details", column: "detail_id"
  add_foreign_key "tudla_accounting_payments", "tudla_accounting_accounts", column: "account_id"
  add_foreign_key "tudla_accounting_payments", "tudla_accounting_contacts", column: "contact_id"
  add_foreign_key "tudla_accounting_payments", "tudla_accounting_entries", column: "entry_id"
  add_foreign_key "tudla_accounting_recurring_entry_lines", "tudla_accounting_accounts", column: "account_id"
  add_foreign_key "tudla_accounting_recurring_entry_lines", "tudla_accounting_recurring_entries", column: "recurring_entry_id"
  add_foreign_key "tudla_accounting_recurring_entry_lines", "tudla_accounting_tax_codes", column: "tax_code_id"
  add_foreign_key "tudla_accounting_tax_codes", "tudla_accounting_accounts", column: "account_id"
  add_foreign_key "tudla_accounting_tax_return_box_parts", "tudla_accounting_accounts", column: "account_id"
  add_foreign_key "tudla_accounting_tax_return_box_parts", "tudla_accounting_tax_codes", column: "tax_code_id"
  add_foreign_key "tudla_accounting_tax_return_box_parts", "tudla_accounting_tax_return_boxes", column: "box_id", on_delete: :cascade
  add_foreign_key "tudla_accounting_tax_return_box_parts", "tudla_accounting_tax_return_boxes", column: "from_box_id", on_delete: :cascade
  add_foreign_key "tudla_accounting_tax_return_boxes", "tudla_accounting_tax_return_forms", column: "form_id", on_delete: :cascade
end
