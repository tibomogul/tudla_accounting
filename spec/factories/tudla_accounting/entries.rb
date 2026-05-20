FactoryBot.define do
  factory :tudla_accounting_entry, class: "TudlaAccounting::Entry" do
    particulars { "Sample entry" }
    transacted_at { Time.current }
    association :organization, factory: :organization

    to_create { |instance| instance.save(validate: false) }
  end
end
