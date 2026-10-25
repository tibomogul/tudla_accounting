# frozen_string_literal: true

module TudlaAccounting
  # Reads the amounts and other numbers people type and the API is given, all one way:
  #
  #   AmountParser.cents("1,234.50", "AUD")        # => 123450
  #   AmountParser.cents("(5.00)", "AUD")          # => -500
  #   AmountParser.cents("10.005", "AUD")          # ArgumentError: too many decimal places
  #   AmountParser.cents("10.005", "AUD", round: true) # => 1001 (an import)
  #   AmountParser.decimal("1.65")                 # => 1.65 (a rate, a quantity, a percentage)
  #
  # A number is digits with "." for decimals, optionally grouped in thousands by commas
  # ("1,234,567.89"), signed by a leading "+" or "-" or by parentheses for a negative.
  # Nothing else is read: no other separators ("1.234,50", "10,00"), exponents ("1e3"),
  # underscores, symbols or words, so a number is never half read. Blank is nil. A
  # spreadsheet's numeric cell is taken as it is.
  #
  # An amount can't have more decimal places than its currency (cents for the dollar, none
  # for the yen) unless round: is given, when it is rounded as the configured rounding
  # says, as Money rounds; imports round, as bank and spreadsheet files carry extra places.
  module AmountParser
    NUMBER = /\A[+-]?(?:\d{1,3}(?:,\d{3})+|\d+)?(?:\.\d*)?\z/

    module_function

    # A typed number, or nil when blank; ArgumentError ("lots isn't a number") otherwise.
    def decimal(text)
      return BigDecimal(text.to_s) if text.is_a?(Numeric) && text.finite?

      typed = text.to_s.strip
      return if typed.empty?

      negative = typed.start_with?("(") && typed.end_with?(")")
      digits = negative ? typed[1...-1].strip : typed
      unless digits.match?(NUMBER) && digits.match?(/\d/) && !(negative && digits.match?(/\A[+-]/))
        raise ArgumentError, "#{text} isn't a number"
      end

      value = BigDecimal(digits.delete(","))
      negative ? -value : value
    end

    # Cents of a currency for a typed amount, or nil when blank; ArgumentError ("lots isn't
    # an amount", or too many decimal places) otherwise.
    def cents(text, currency, round: false)
      number = begin
        decimal(text)
      rescue ArgumentError
        raise ArgumentError, "#{text} isn't an amount"
      end
      return if number.nil?

      currency = Money::Currency.wrap(currency)
      unless round || number == number.round(currency.exponent)
        places = currency.exponent.zero? ? "none" : currency.exponent
        raise ArgumentError, "#{text} has too many decimal places for #{currency.iso_code}, which has #{places}"
      end
      Money.from_amount(number, currency).cents
    end

    # An amount as these read it back ("1234.50", "-1000" for the yen), whatever the
    # currency's own style: for form fields and the amounts given to Entry.create_from_ruby_hash.
    def text(money) = money.format(symbol: false, thousands_separator: "", decimal_mark: ".")
  end
end
