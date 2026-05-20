FactoryBot.define do
  factory :tudla_accounting_bank_account_balance, class: "TudlaAccounting::BankAccountBalance" do
    sequence(:name) { |n| "Bank Account #{n}" }
    currency { "USD" }
    balance_cents { 0 }
    association :account, factory: :tudla_accounting_account
  end
end
