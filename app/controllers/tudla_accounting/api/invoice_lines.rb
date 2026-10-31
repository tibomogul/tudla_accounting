module TudlaAccounting
  module Api
    # Reads an invoice's lines as the JSON API is given them (documents and recurring
    # invoices): description, quantity (1 if not given), unit_price, account_code, tax_code
    # and dimensions (dimension code => value code).
    module InvoiceLines
      private

      # The lines' attributes, their prices in currency; ArgumentError naming the line on
      # anything wrong.
      def line_attributes(currency)
        lines = body[:lines]
        raise ArgumentError, "lines must be a list" unless lines.is_a?(Array)

        lines.each_with_index.map do |line, index|
          label = "Line #{index + 1}"
          raise ArgumentError, "#{label} must be an object" unless line.is_a?(Hash)

          { description: line[:description].to_s, quantity: (line[:quantity].presence && decimal(line[:quantity], "#{label}'s quantity")) || 1,
            unit_price_cents: cents(line[:unit_price], "#{label}'s unit_price", currency: currency), account: account_by_code(line[:account_code], label),
            tax_code: line[:tax_code].presence && tax_code_by_code(line[:tax_code], label), dimension_value_ids: dimension_value_ids(line[:dimensions], label) }
        end
      end

      # A line's dimensions, as dimension code => value code.
      def dimension_value_ids(given, label)
        return [] if given.blank?
        raise ArgumentError, "#{label}'s dimensions must be an object of dimension code => value code" unless given.is_a?(Hash)

        given.map do |dimension_code, value_code|
          dimension = organization_scope(Dimension).find_by(code: dimension_code.to_s) or raise ArgumentError, "#{label}: there is no dimension #{dimension_code}"
          value = dimension.dimension_values.find_by(code: value_code.to_s) or raise ArgumentError, "#{label}: there is no #{dimension.name} value #{value_code}"
          value.id
        end
      end
    end
  end
end
