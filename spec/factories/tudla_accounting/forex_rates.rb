FactoryBot.define do
  factory :tudla_accounting_forex_rate, class: "TudlaAccounting::ForexRate" do
    from { "USD" }
    to { "EUR" }
    rate { BigDecimal("0.85000000") }
    year { 2026 }
    month { 1 }
    day { 1 }
  end
end
