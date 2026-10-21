# A customer's payment: its entry is a receipt, applied to the invoice it is related to.
# The customer is the engine's contact the invoice was to.
class Demo::Payment < ApplicationRecord
  self.table_name = "demo_payments"

  belongs_to :customer, class_name: "TudlaAccounting::Contact"
end
