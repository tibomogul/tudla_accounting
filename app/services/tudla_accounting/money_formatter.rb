# frozen_string_literal: true

module TudlaAccounting
  # Writes amounts for people, all one way, in an organization's style (its NumberFormat:
  # the number_format setting, or its home currency's marks), whatever currency the
  # amount is in:
  #
  #   MoneyFormatter.number(Money.new(123456, "EUR"), organization)   # => "1,234.56" (a table's column)
  #   MoneyFormatter.labelled(Money.new(123456, "AUD"), organization) # => "$1,234.56"
  #   MoneyFormatter.labelled(Money.new(123456, "EUR"), organization) # => "EUR 1,234.56"
  #   MoneyFormatter.labelled(Money.new(123456, "EUR"), "EUR")        # => "€1.234,56"
  #
  # The organization can be its currency instead, for its marks without the setting.
  # labelled is for an amount standing alone (a heading, a message, an email, a document):
  # the home currency's symbol, or for any other currency its code, as symbols such as $
  # are shared. Files and form fields take AmountParser.text ("1234.56") instead, which
  # reads back.
  module MoneyFormatter
    module_function

    # The number alone, signed, in the organization's marks.
    def number(money, organization)
      NumberFormat.for(organization).number(money)
    end

    # The number with the home currency's symbol, or another currency's code.
    def labelled(money, organization)
      home = Money::Currency.wrap(organization.respond_to?(:currency) ? organization.currency : organization)
      return NumberFormat.for(organization).number(money, symbol: true, sign_before_symbol: true) if money.currency == home && home.symbol.present?

      "#{money.currency.iso_code} #{number(money, organization)}"
    end
  end
end
