# frozen_string_literal: true

module TudlaAccounting
  # How an organization's pages write numbers: its decimal mark and thousands separator.
  # The number_format setting picks them per organization (:point for "1,234.56", :comma
  # for "1.234,56"); without it they are its home currency's own.
  #
  #   NumberFormat.for(organization).number(Money.new(123456, "EUR")) # => "1.234,56" (comma books)
  #   NumberFormat.for("AUD")                                          # the Australian dollar's marks
  class NumberFormat < Data.define(:decimal_mark, :thousands_separator)
    STYLES = { point: new(decimal_mark: ".", thousands_separator: ","), comma: new(decimal_mark: ",", thousands_separator: ".") }.freeze

    # An organization's (by the number_format setting, or its currency), or a currency's.
    def self.for(owner)
      return of_currency(owner) unless owner.respond_to?(:currency)

      style = TudlaAccounting.configuration.number_format_for(owner)
      style ? STYLES.fetch(style) : of_currency(owner.currency)
    end

    def self.of_currency(currency)
      currency = Money::Currency.wrap(currency)
      new(decimal_mark: currency.decimal_mark, thousands_separator: currency.thousands_separator)
    end

    # An amount's number, signed, in these marks.
    def number(money, **options) = money.format(symbol: false, decimal_mark: decimal_mark, thousands_separator: thousands_separator, **options)
  end
end
