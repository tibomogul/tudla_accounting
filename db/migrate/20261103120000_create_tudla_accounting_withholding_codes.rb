# A tax withheld from a payment (the BIR's ATCs, for the Philippines): its code and rate,
# and the accounts it posts to: a liability for tax withheld from suppliers, owed to the
# tax authority, and an asset for tax customers withhold, claimed against income tax. A
# contact's default starts its bills' lines.
class CreateTudlaAccountingWithholdingCodes < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_withholding_codes do |t|
      t.references :organization, polymorphic: true, null: false, index: false
      t.string :code, null: false
      t.string :name, null: false
      t.decimal :rate, precision: 9, scale: 6, null: false
      t.references :payable_account, foreign_key: { to_table: :tudla_accounting_accounts }, index: { name: "index_tudla_accounting_withholding_codes_on_payable_account" }
      t.references :creditable_account, foreign_key: { to_table: :tudla_accounting_accounts }, index: { name: "index_tudla_accounting_withholding_codes_on_creditable_account" }
      t.boolean :active, null: false, default: true
      t.timestamps
      t.index %w[organization_type organization_id code], unique: true, name: "tudla_accounting_withholding_codes_unique_key"
      t.check_constraint "rate > 0::numeric AND rate < 1::numeric", name: "tudla_accounting_withholding_codes_rate_range"
      t.check_constraint "payable_account_id IS NOT NULL OR creditable_account_id IS NOT NULL", name: "tudla_accounting_withholding_codes_account_given"
    end
    add_reference :tudla_accounting_contacts, :default_withholding_code, foreign_key: { to_table: :tudla_accounting_withholding_codes },
                                                                         index: { name: "index_tudla_accounting_contacts_on_default_withholding_code" }
  end
end
