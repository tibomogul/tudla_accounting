class CreateTudlaAccountingAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_accounts do |t|
      t.string :code, null: false
      t.string :name, null: false
      t.integer :category, null: false
      t.string :ancestry, null: false, default: "/"
      t.integer :ancestry_depth, null: false, default: 0
      t.references :organization, polymorphic: true, null: false
      t.references :contra_account, foreign_key: { to_table: :tudla_accounting_accounts }, null: true
      t.string :currency

      t.timestamps
    end

    add_index :tudla_accounting_accounts, :code
    add_index :tudla_accounting_accounts, :name
    add_index :tudla_accounting_accounts, :category
    add_index :tudla_accounting_accounts, :ancestry
  end
end
