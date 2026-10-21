# An accrual or prepayment that undoes itself: posting an entry with reverse_on also
# posts its reversal, dated that day.
class AddReverseOnToTudlaAccountingEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :tudla_accounting_entries, :reverse_on, :date
  end
end
