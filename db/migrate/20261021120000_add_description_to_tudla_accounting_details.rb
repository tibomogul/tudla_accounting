# A line's own description, for entries whose lines each record something different (a
# payroll's deductions, an expense claim's receipts). Fixed once posted, like the line.
class AddDescriptionToTudlaAccountingDetails < ActiveRecord::Migration[8.1]
  def change
    add_column :tudla_accounting_details, :description, :string
  end
end
