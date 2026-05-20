FactoryBot.define do
  factory :organization do
    sequence(:name) { |n| "Organization #{n}" }
    currency { "USD" }
  end
end
