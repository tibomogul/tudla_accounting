FactoryBot.define do
  factory :tudla_accounting_foreign_exchange, class: "TudlaAccounting::ForeignExchange" do
    association :detail, factory: :tudla_accounting_detail
    rate { BigDecimal("1.25000000") }
    other_currency_cents { 12_500 }
    other_currency { "EUR" }
  end
end
