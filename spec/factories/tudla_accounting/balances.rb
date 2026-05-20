FactoryBot.define do
  factory :tudla_accounting_balance, class: "TudlaAccounting::Balance" do
    association :account, factory: :tudla_accounting_account
    association :period, factory: :tudla_accounting_period
    starting_amount_cents { 0 }
    current_amount_cents { 0 }
    ending_amount_cents { 0 }
    currency { "USD" }
    association :organization, factory: :organization
  end
end
