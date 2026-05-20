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

ActiveRecord::Schema[8.1].define(version: 2026_05_19_034727) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "organizations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency"
    t.string "name"
    t.datetime "updated_at", null: false
  end

  create_table "tudla_accounting_accounts", force: :cascade do |t|
    t.string "ancestry", default: "/", null: false
    t.integer "ancestry_depth", default: 0, null: false
    t.integer "category", null: false
    t.string "code", null: false
    t.bigint "contra_account_id"
    t.datetime "created_at", null: false
    t.string "currency"
    t.string "name", null: false
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.datetime "updated_at", null: false
    t.index ["ancestry"], name: "index_tudla_accounting_accounts_on_ancestry"
    t.index ["category"], name: "index_tudla_accounting_accounts_on_category"
    t.index ["code"], name: "index_tudla_accounting_accounts_on_code"
    t.index ["contra_account_id"], name: "index_tudla_accounting_accounts_on_contra_account_id"
    t.index ["name"], name: "index_tudla_accounting_accounts_on_name"
    t.index ["organization_type", "organization_id"], name: "index_tudla_accounting_accounts_on_organization"
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
    t.index ["account_id"], name: "index_tudla_accounting_bank_account_balances_on_account_id"
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
    t.index ["detail_id"], name: "index_tudla_accounting_carrying_amounts_on_detail_id"
    t.index ["related_party_type", "related_party_id"], name: "index_tudla_accounting_carrying_amounts_on_related_party"
  end

  create_table "tudla_accounting_details", force: :cascade do |t|
    t.bigint "account_id"
    t.bigint "amount_cents"
    t.bigint "balance_id"
    t.datetime "created_at", null: false
    t.string "currency"
    t.bigint "entry_id"
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.integer "tally"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_tudla_accounting_details_on_account_id"
    t.index ["balance_id"], name: "index_tudla_accounting_details_on_balance_id"
    t.index ["entry_id"], name: "index_tudla_accounting_details_on_entry_id"
    t.index ["organization_type", "organization_id"], name: "index_tudla_accounting_details_on_organization"
  end

  create_table "tudla_accounting_entries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.text "particulars"
    t.datetime "posted_at"
    t.bigint "related_id"
    t.string "related_type"
    t.bigint "source_id"
    t.string "source_type"
    t.datetime "transacted_at"
    t.datetime "updated_at", null: false
    t.index ["organization_type", "organization_id"], name: "index_tudla_accounting_entries_on_organization"
    t.index ["posted_at"], name: "index_tudla_accounting_entries_on_posted_at"
    t.index ["related_type", "related_id"], name: "index_tudla_accounting_entries_on_related"
    t.index ["source_type", "source_id"], name: "index_tudla_accounting_entries_on_source"
    t.index ["transacted_at"], name: "index_tudla_accounting_entries_on_transacted_at"
  end

  create_table "tudla_accounting_foreign_exchanges", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "detail_id", null: false
    t.string "other_currency"
    t.bigint "other_currency_cents"
    t.decimal "rate", precision: 24, scale: 8
    t.datetime "updated_at", null: false
    t.index ["detail_id"], name: "index_tudla_accounting_foreign_exchanges_on_detail_id"
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
  end

  create_table "tudla_accounting_periods", force: :cascade do |t|
    t.string "ancestry", default: "/", null: false
    t.integer "ancestry_depth", default: 0, null: false
    t.integer "children_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "from_date", null: false
    t.bigint "organization_id", null: false
    t.string "organization_type", null: false
    t.datetime "thru_date", null: false
    t.datetime "updated_at", null: false
    t.index ["ancestry"], name: "index_tudla_accounting_periods_on_ancestry"
    t.index ["organization_type", "organization_id"], name: "index_tudla_accounting_periods_on_organization"
  end

  add_foreign_key "tudla_accounting_accounts", "tudla_accounting_accounts", column: "contra_account_id"
  add_foreign_key "tudla_accounting_balances", "tudla_accounting_accounts", column: "account_id"
  add_foreign_key "tudla_accounting_balances", "tudla_accounting_periods", column: "period_id"
  add_foreign_key "tudla_accounting_bank_account_balances", "tudla_accounting_accounts", column: "account_id"
  add_foreign_key "tudla_accounting_carrying_amount_forexes", "tudla_accounting_carrying_amounts", column: "carrying_amount_id"
  add_foreign_key "tudla_accounting_carrying_amounts", "tudla_accounting_details", column: "detail_id"
  add_foreign_key "tudla_accounting_details", "tudla_accounting_accounts", column: "account_id"
  add_foreign_key "tudla_accounting_details", "tudla_accounting_balances", column: "balance_id"
  add_foreign_key "tudla_accounting_details", "tudla_accounting_entries", column: "entry_id"
  add_foreign_key "tudla_accounting_foreign_exchanges", "tudla_accounting_details", column: "detail_id"
end
