# The demo's payments are the engine's own now. Books seeded before this need reseeding
# (bin/setup --reset).
class DropDemoPayments < ActiveRecord::Migration[8.1]
  def up
    drop_table :demo_payments
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
