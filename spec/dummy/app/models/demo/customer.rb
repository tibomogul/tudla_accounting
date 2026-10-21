# One of Demo Co's customers, who owes it for invoices on credit.
class Demo::Customer < ApplicationRecord
  self.table_name = "demo_customers"

  has_many :invoices, class_name: "Demo::Invoice"
end
