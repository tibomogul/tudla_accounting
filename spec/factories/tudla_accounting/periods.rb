FactoryBot.define do
  # Periods run from the start of their first day to the end of their last day,
  # matching TudlaAccounting::PeriodCreator.
  factory :tudla_accounting_period, class: "TudlaAccounting::Period" do
    from_date { Time.zone.local(2026, 1, 1) }
    thru_date { Time.zone.local(2026, 12, 31).end_of_day }
    association :organization, factory: :organization
  end
end
