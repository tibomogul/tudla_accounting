FactoryBot.define do
  factory :tudla_accounting_carrying_amount, class: "TudlaAccounting::CarryingAmount" do
    association :detail, factory: :tudla_accounting_detail
    amount_cents { 10_000 }
    carrying_amount_type { :receivable }
    due_date { 30.days.from_now }
    association :related_party, factory: :organization
  end
end
