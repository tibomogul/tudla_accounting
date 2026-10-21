# frozen_string_literal: true

require "nokogiri"

module TudlaAccounting
  class BankStatementImporter
    # Reads an ISO 20022 CAMT.053 bank statement (any version): each booked Ntry as a line,
    # known by the bank's AcctSvcrRef (or NtryRef), dated by its booking date, money in when
    # CRDT and out when DBIT, described by the remittance information or the other party's
    # name, with the end-to-end id as its reference; the CLBD balance as the closing
    # balance. Pending entries are left out. One account's statements per file.
    class Camt053
      def initialize(text, currency)
        @text = text
        @currency = currency
      end

      def call
        document = Nokogiri::XML(@text) { |config| config.strict.nonet }
        document.remove_namespaces!
        statements = document.xpath("//BkToCstmrStmt/Stmt")
        raise ArgumentError, "The CAMT file holds no statement" if statements.empty?

        accounts = statements.map { |statement| text(statement, "Acct/Id/IBAN") || text(statement, "Acct/Id/Othr/Id") }.uniq
        raise ArgumentError, "The CAMT file holds statements for #{accounts.size} accounts; import one account's at a time" if accounts.size > 1

        seen = Hash.new(0)
        entries = statements.flat_map { |statement| statement.xpath("Ntry").select { |entry| booked?(entry) } }
        { lines: entries.map { |entry| line(entry, seen) }, closing: closing(statements.last) }
      rescue Nokogiri::XML::SyntaxError => e
        raise ArgumentError, "The file isn't XML that can be read: #{e.message.strip}"
      end

      private

      def text(node, path)
        node.at_xpath(path)&.text&.strip.presence
      end

      def booked?(entry)
        (text(entry, "Sts/Cd") || text(entry, "Sts")) == "BOOK"
      end

      def line(entry, seen)
        amount = entry.at_xpath("Amt")
        raise ArgumentError, "An entry has no amount" unless amount

        currency = amount["Ccy"]
        raise ArgumentError, "The statement is in #{currency}; the account is held in #{@currency}" if currency && currency != @currency

        cents = money(amount.text)
        cents = -cents if text(entry, "CdtDbtInd") == "DBIT"
        occurred_on = date(text(entry, "BookgDt/Dt") || text(entry, "BookgDt/DtTm") || text(entry, "ValDt/Dt"))
        details = entry.at_xpath("NtryDtls/TxDtls")
        description = details && (details.xpath("RmtInf/Ustrd").map { |part| part.text.strip }.join(" ").presence ||
                                  text(details, cents.negative? ? "RltdPties/Cdtr/Nm" : "RltdPties/Dbtr/Nm") ||
                                  text(details, cents.negative? ? "RltdPties/Cdtr/Pty/Nm" : "RltdPties/Dbtr/Pty/Nm"))
        reference = details && text(details, "Refs/EndToEndId")
        line = { occurred_on: occurred_on, amount_cents: cents, description: description || text(entry, "AddtlNtryInf") || "(no description)",
                 reference: (reference unless reference == "NOTPROVIDED") }
        line.merge(external_id: external_id(entry, line, seen))
      end

      # The bank's reference for the entry, or (without one) a digest of what it says.
      def external_id(entry, line, seen)
        bank_id = text(entry, "AcctSvcrRef") || text(entry, "NtryRef")
        return "id:#{bank_id}" if bank_id

        key = line.values_at(:occurred_on, :description, :amount_cents, :reference).join("|")
        "camt:#{Digest::SHA256.hexdigest("#{key}|#{seen[key] += 1}")[0, 32]}"
      end

      def closing(statement)
        balance = statement.xpath("Bal").find { |node| text(node, "Tp/CdOrPrtry/Cd") == "CLBD" }
        return unless balance

        cents = money(text(balance, "Amt"))
        { on: date(text(balance, "Dt/Dt") || text(balance, "Dt/DtTm")), cents: text(balance, "CdtDbtInd") == "DBIT" ? -cents : cents }
      end

      def date(value)
        Date.iso8601(value.to_s[0, 10])
      rescue Date::Error
        raise ArgumentError, "The statement has a date that can't be read: #{value}"
      end

      def money(value)
        Money.from_amount(BigDecimal(value.to_s), @currency).cents
      rescue ArgumentError, TypeError
        raise ArgumentError, "The statement has an amount that can't be read: #{value}"
      end
    end
  end
end
