# frozen_string_literal: true

require "cgi"

module TudlaAccounting
  class BankStatementImporter
    # Reads an OFX or QFX statement (the SGML of OFX 1.x, or the XML of OFX 2.x), bank or
    # credit card: each STMTTRN as a line, known by its FITID, dated by DTPOSTED, described
    # by NAME and MEMO, with CHECKNUM or REFNUM as its reference; LEDGERBAL as the closing
    # balance. One account's statement per file.
    class Ofx
      def initialize(text, currency)
        @text = text
        @currency = currency
      end

      # { lines: [...], closing: { on:, cents: } or nil }, lines as BankStatementImporter
      # stores them.
      def call
        statements = blocks(@text, "STMTRS") + blocks(@text, "CCSTMTRS")
        raise ArgumentError, "The OFX file holds no statement" if statements.empty?

        accounts = statements.map { |statement| field(statement, "ACCTID") }.uniq
        raise ArgumentError, "The OFX file holds statements for #{accounts.size} accounts; import one account's at a time" if accounts.size > 1

        statements.each do |statement|
          currency = field(statement, "CURDEF")
          raise ArgumentError, "The statement is in #{currency}; the account is held in #{@currency}" if currency && currency.upcase != @currency
        end
        { lines: statements.flat_map { |statement| blocks(statement, "STMTTRN").map { |transaction| line(transaction) } },
          closing: closing(statements.last) }
      end

      private

      # The text of each <TAG>...</TAG> aggregate (OFX's aggregates are closed even in SGML).
      def blocks(text, tag)
        text.scan(%r{<#{tag}>(.*?)</#{tag}>}mi).flatten
      end

      # An element's value: up to the next tag or line end, so closed (XML) and unclosed
      # (SGML) elements read alike.
      def field(text, tag)
        value = text[/<#{tag}>([^<\r\n]*)/i, 1]&.strip
        value.presence && CGI.unescapeHTML(value)
      end

      def line(transaction)
        id = field(transaction, "FITID")
        raise ArgumentError, "A transaction has no FITID" unless id

        amount = cents(field(transaction, "TRNAMT"), id)
        raise ArgumentError, "Transaction #{id} has no amount" if amount.zero?

        { occurred_on: date(field(transaction, "DTPOSTED"), id), amount_cents: amount, external_id: "id:#{id}",
          description: [ field(transaction, "NAME"), field(transaction, "MEMO") ].compact.uniq.join(" - ").presence || "(no description)",
          reference: field(transaction, "CHECKNUM") || field(transaction, "REFNUM") }
      end

      def closing(statement)
        balance = blocks(statement, "LEDGERBAL").first
        amount = balance && field(balance, "BALAMT")
        amount && { on: date(field(balance, "DTASOF"), "LEDGERBAL"), cents: cents(amount, "LEDGERBAL") }
      end

      # YYYYMMDD, maybe followed by a time and zone: the date the bank gives.
      def date(text, where)
        Date.strptime(text.to_s[0, 8], "%Y%m%d")
      rescue Date::Error
        raise ArgumentError, "#{where} has a date that can't be read: #{text}"
      end

      def cents(text, where)
        text = text.to_s.strip
        text = text.tr(",", ".") if text.include?(",") && !text.include?(".") # a decimal comma
        Money.from_amount(BigDecimal(text), @currency).cents
      rescue ArgumentError, TypeError
        raise ArgumentError, "#{where} has an amount that can't be read: #{text}"
      end
    end
  end
end
