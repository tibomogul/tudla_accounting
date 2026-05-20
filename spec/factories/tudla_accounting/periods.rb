FactoryBot.define do
  factory :tudla_accounting_period, class: "TudlaAccounting::Period" do
    from_date { Time.zone.local(2026, 1, 1) }
    thru_date { Time.zone.local(2026, 12, 31) }
    association :organization, factory: :organization
  end
end
