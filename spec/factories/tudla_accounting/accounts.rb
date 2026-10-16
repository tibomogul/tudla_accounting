FactoryBot.define do
  factory :tudla_accounting_account, class: "TudlaAccounting::Account" do
    sequence(:code) { |n| "100#{n}" }
    sequence(:name) { |n| "Account #{n}" }
    category { :asset }
    currency { "USD" }
    association :organization, factory: :organization

    # Roles change only through AccountRoleAssigner, so create gives it one afterwards.
    transient { role { nil } }
    after(:create) { |account, factory| TudlaAccounting::AccountRoleAssigner.save!(account, factory.role) if factory.role }
  end
end
