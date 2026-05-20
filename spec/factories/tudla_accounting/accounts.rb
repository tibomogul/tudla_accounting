FactoryBot.define do
  factory :tudla_accounting_account, class: "TudlaAccounting::Account" do
    sequence(:code) { |n| "100#{n}" }
    sequence(:name) { |n| "Account #{n}" }
    category { :asset }
    currency { "USD" }
    association :organization, factory: :organization
  end
end
