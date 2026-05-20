FactoryBot.define do
  factory :tudla_accounting_carrying_amount_forex, class: "TudlaAccounting::CarryingAmountForex" do
    association :carrying_amount, factory: :tudla_accounting_carrying_amount
    other_currency_amount_cents { 12_500 }
    other_currency { "EUR" }
    transaction_rate { BigDecimal("1.25000000") }
    conversion_date { Date.current }
  end
end
