# frozen_string_literal: true

module TudlaAccounting
  # Writes amounts for people, all one way, in an organization's style (its home currency's
  # decimal mark and thousands separator), whatever currency the amount is in:
  #
  #   MoneyFormatter.number(Money.new(123456, "EUR"), "AUD")   # => "1,234.56" (a table's column)
  #   MoneyFormatter.labelled(Money.new(123456, "AUD"), "AUD") # => "$1,234.56"
  #   MoneyFormatter.labelled(Money.new(123456, "EUR"), "AUD") # => "EUR 1,234.56"
  #   MoneyFormatter.labelled(Money.new(123456, "EUR"), "EUR") # => "€1.234,56"
  #
  # labelled is for an amount standing alone (a heading, a message, an email, a document):
  # the home currency's symbol, or for any other currency its code, as symbols such as $
  # are shared. Files and form fields take AmountParser.text ("1234.56") instead, which
  # reads back.
  module MoneyFormatter
    module_function

    # The number alone, signed, with the home currency's marks.
    def number(money, home)
      home = Money::Currency.wrap(home)
      money.format(symbol: false, decimal_mark: home.decimal_mark, thousands_separator: home.thousands_separator)
    end

    # The number with the home currency's symbol, or another currency's code.
    def labelled(money, home)
      home = Money::Currency.wrap(home)
      return money.format(sign_before_symbol: true) if money.currency == home && home.symbol.present?

      "#{money.currency.iso_code} #{number(money, home)}"
    end
  end
end
