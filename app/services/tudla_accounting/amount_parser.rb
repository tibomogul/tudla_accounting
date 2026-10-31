# frozen_string_literal: true

module TudlaAccounting
  # Reads the amounts and other numbers people type and the API is given, all one way:
  #
  #   AmountParser.cents("1,234.50", "AUD")        # => 123450
  #   AmountParser.cents("(5.00)", "AUD")          # => -500
  #   AmountParser.cents("10.005", "AUD")          # ArgumentError: too many decimal places
  #   AmountParser.cents("10.005", "AUD", round: true) # => 1001 (an import)
  #   AmountParser.decimal("1.65")                 # => 1.65 (a rate, a quantity, a percentage)
  #   AmountParser.cents("1.234,50", "EUR", format: NumberFormat::STYLES[:comma]) # => 123450 (a page in comma books)
  #
  # A number is digits with the format's decimal mark ("." unless one is given), optionally
  # grouped in thousands by its separator ("1,234,567.89"), signed by a leading "+" or "-"
  # or by parentheses for a negative. Nothing else is read: no other separators
  # ("1.234,50" with "."), exponents ("1e3"), underscores, symbols or words, so a number is
  # never half read. Blank is nil. A spreadsheet's numeric cell is taken as it is. The
  # pages read in the organization's NumberFormat; the JSON API, files and imports in the
  # default.
  #
  # An amount can't have more decimal places than its currency (cents for the dollar, none
  # for the yen) unless round: is given, when it is rounded as the configured rounding
  # says, as Money rounds; imports round, as bank and spreadsheet files carry extra places.
  module AmountParser
    POINT = NumberFormat::STYLES.fetch(:point)

    module_function

    # A typed number, or nil when blank; ArgumentError ("lots isn't a number") otherwise.
    def decimal(text, format: POINT)
      return BigDecimal(text.to_s) if text.is_a?(Numeric) && text.finite?

      typed = text.to_s.strip
      return if typed.empty?

      negative = typed.start_with?("(") && typed.end_with?(")")
      digits = negative ? typed[1...-1].strip : typed
      unless digits.match?(pattern(format)) && digits.match?(/\d/) && !(negative && digits.match?(/\A[+-]/))
        raise ArgumentError, "#{text} isn't a number#{hint(format)}"
      end

      digits = digits.delete(format.thousands_separator) if format.thousands_separator.present?
      value = BigDecimal(digits.tr(format.decimal_mark, "."))
      negative ? -value : value
    end

    # Cents of a currency for a typed amount, or nil when blank; ArgumentError ("lots isn't
    # an amount", or too many decimal places) otherwise.
    def cents(text, currency, round: false, format: POINT)
      number = begin
        decimal(text, format: format)
      rescue ArgumentError
        raise ArgumentError, "#{text} isn't an amount#{hint(format)}"
      end
      return if number.nil?

      currency = Money::Currency.wrap(currency)
      unless round || number == number.round(currency.exponent)
        places = currency.exponent.zero? ? "none" : currency.exponent
        raise ArgumentError, "#{text} has too many decimal places for #{currency.iso_code}, which has #{places}"
      end
      Money.from_amount(number, currency).cents
    end

    # An amount as these read it back ("1234.50", "-1000" for the yen; "1234,50" in a comma
    # format), whatever the currency's own style: for form fields and the amounts given to
    # Entry.create_from_ruby_hash.
    def text(money, format: POINT) = money.format(symbol: false, thousands_separator: "", decimal_mark: format.decimal_mark)

    # Any other number as these read it back, without trailing zeros: "2.5", "1.6", "10"
    # ("2,5" in a comma format). For quantities, rates and percentages.
    def number_text(value, format: POINT) = value.to_d.to_s("F").sub(/\.?0+\z/, "").tr(".", format.decimal_mark)

    private_class_method def pattern(format)
      @patterns ||= {}
      @patterns[format] ||= begin
        mark = Regexp.escape(format.decimal_mark)
        grouped = format.thousands_separator.present? ? "\\d{1,3}(?:#{Regexp.escape(format.thousands_separator)}\\d{3})+|" : ""
        /\A[+-]?(?:#{grouped}\d+)?(?:#{mark}\d*)?\z/
      end
    end

    # How to write one, when the format isn't the default: ", written like 1.234,56".
    private_class_method def hint(format)
      format == POINT ? "" : ", written like #{format.number(Money.from_amount(1234.56, 'USD'))}"
    end
  end
end
