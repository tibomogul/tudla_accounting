FactoryBot.define do
  factory :tudla_accounting_detail, class: "TudlaAccounting::Detail" do
    association :entry, factory: :tudla_accounting_entry
    association :account, factory: :tudla_accounting_account
    tally { :debit }
    amount_cents { 10_000 }
    currency { "USD" }
    association :organization, factory: :organization
  end
end
