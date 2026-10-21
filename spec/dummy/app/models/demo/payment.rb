# A customer's payment: its entry is a receipt, applied to the invoice it is related to.
class Demo::Payment < ApplicationRecord
  self.table_name = "demo_payments"

  belongs_to :customer, class_name: "Demo::Customer"
end
