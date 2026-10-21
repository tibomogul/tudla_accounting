# An invoice on credit: its entry opens a receivable for the customer, due on due_date
# (the engine's carrying_amount_sources and related_party_method, set in
# config/initializers/demo.rb).
class Demo::Invoice < ApplicationRecord
  self.table_name = "demo_invoices"

  belongs_to :customer, class_name: "Demo::Customer"
end
