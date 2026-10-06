# A closed period takes no more postings; see TudlaAccounting::Period#close!.
class AddClosedAtToTudlaAccountingPeriods < ActiveRecord::Migration[8.1]
  def change
    add_column :tudla_accounting_periods, :closed_at, :datetime
  end
end
