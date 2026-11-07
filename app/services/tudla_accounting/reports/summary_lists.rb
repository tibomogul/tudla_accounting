# frozen_string_literal: true

module TudlaAccounting
  module Reports
    # What was sold to each customer and bought from each supplier, a row per contact per
    # month, over a run of months, in the organization's currency: the Philippines' summary
    # lists of sales and purchases (the SLSP), as RR 16-2005 lists their fields.
    #
    # It reads the posted lines by the month they were posted, as the tax summary does on
    # the accrual basis, so a void or credit note counts in its own month and a row can be
    # negative. A line goes by its tax code: exempt, zero-rated, or taxed, which on a
    # purchase splits by the code's purchase_type. A line on an invoice or bill with no tax
    # code counts as exempt, as in the sales journal, and uncoded says how much that is.
    # Lines with a code on anything else have no customer or supplier to go by, so they
    # share a row with no contact, and each list still ties to the tax summary (checks).
    #
    #   report = SummaryLists.new(organization, from: january, thru: march)
    #   report.sales     # => [#<Row month contact exempt zero_rated taxable ... tax>, ...]
    #   report.purchases # => the same, with taxable split into services, capital_goods...
    class SummaryLists
      BASES = %i[exempt zero_rated taxable services capital_goods other_goods not_set].freeze

      Row = Data.define(:month, :contact, *BASES, :tax) do
        def total = BASES.sum(Money.new(0, tax.currency)) { |base| public_send(base) }
      end
      Check = Data.define(:base, :tax)

      attr_reader :organization, :from, :thru

      def initialize(organization, from:, thru:)
        @organization = organization
        @from = from
        @thru = thru
      end

      def sales = rows_for(:sales)
      def purchases = rows_for(:purchases)
      def rows_for(side) = worked_out.fetch(side).fetch(:rows)

      # A row of each amount added up.
      def total(side)
        (BASES + [ :tax ]).to_h { |name| [ name, rows_for(side).sum(money(0)) { |row| row.public_send(name) } ] }
      end

      # What lines without a tax code add to the exempt column.
      def uncoded(side) = money(worked_out.fetch(side).fetch(:uncoded))

      # The purchases codes that have been used here with no purchase_type.
      def codes_not_set = worked_out.fetch(:purchases).fetch(:not_set).to_a.sort_by(&:code)

      def no_contact?(side) = rows_for(side).any? { |row| row.contact.nil? }

      # Who has no TIN: only a VAT sale needs the buyer's, and every purchase the seller's.
      def missing_tin(side)
        rows_for(side).select { |row| row.contact && row.contact.tax_number.blank? && (side == :purchases || !row.taxable.zero?) }.map { |row| row.contact.name }.uniq
      end

      # The list less the tax summary, on the accrual basis; lines with no tax code are
      # only here, so they aren't counted.
      def difference(side)
        summary = tax_summary.fetch(side)
        totals = total(side)
        Check.new(base: BASES.sum(money(0)) { |base| totals[base] } - uncoded(side) - summary[:base], tax: totals[:tax] - summary[:tax])
      end

      private

      def worked_out
        @worked_out ||= begin
          sides = { sales: blank_side, purchases: blank_side }
          grouped.each do |(month, contact_id, kind, code_id, role, tally), cents|
            code = code_id && tax_codes.fetch(code_id)
            side = code ? code.kind.to_sym : Document::KINDS.fetch(kind).fetch(:side)
            signed = (tally == Detail::TALLY_CREDIT) == (side == :sales) ? cents : -cents
            column = role == "tax" ? :tax : base_column(side, code)
            held = sides.fetch(side)
            held[:amounts][[ month, contact_id ]][column] += signed
            held[:uncoded] += signed unless code
            held[:not_set] << code if column == :not_set
          end
          sides.transform_values { |held| { **held, rows: rows(held[:amounts]) } }
        end
      end

      def blank_side = { amounts: Hash.new { |hash, key| hash[key] = Hash.new(0) }, uncoded: 0, not_set: Set.new }

      def base_column(side, code)
        return :exempt unless code
        return code.treatment.to_sym unless code.standard?
        return :taxable if side == :sales

        code.purchase_type&.to_sym || :not_set
      end

      def rows(amounts)
        contacts = Contact.where(id: amounts.keys.filter_map(&:last)).index_by(&:id)
        amounts.filter_map do |(month, contact_id), held|
          next if held.values.all?(&:zero?)

          Row.new(month: Date.parse("#{month}-01"), contact: contacts[contact_id], **(BASES + [ :tax ]).to_h { |name| [ name, money(held[name]) ] })
        end.sort_by { |row| [ row.month, row.contact ? 0 : 1, row.contact&.name.to_s.downcase ] }
      end

      # { [month, contact, document kind, tax code, tax role, tally] => cents }. A reversal
      # has no source of its own, so it goes by the entry it reverses.
      def grouped
        documents = Document.quoted_table_name
        details = Detail.quoted_table_name
        Detail.joins(:entry).joins(<<~SQL.squish)
          LEFT JOIN #{Entry.quoted_table_name} originals ON tudla_accounting_entries.source_id IS NULL
            AND tudla_accounting_entries.related_type = #{quote(Entry.polymorphic_name)} AND originals.id = tudla_accounting_entries.related_id
          LEFT JOIN #{documents} ON #{documents}.id = CASE WHEN tudla_accounting_entries.source_type = #{quote(Document.polymorphic_name)} THEN tudla_accounting_entries.source_id
            WHEN originals.source_type = #{quote(Document.polymorphic_name)} THEN originals.source_id END
        SQL
          .where(organization_type: organization.class.polymorphic_name, organization_id: organization.id, tudla_accounting_entries: { posted_at: from.from_date..thru.thru_date })
          .where("#{details}.tax_code_id IS NOT NULL OR (#{documents}.id IS NOT NULL AND #{details}.account_id NOT IN (?))", not_lines)
          .group(Arel.sql(month_sql), "#{documents}.contact_id", "#{documents}.kind", :tax_code_id, :tax_role, :tally)
          .sum(:amount_cents)
      end

      # The month in the engine's time zone, as the periods have it.
      def month_sql
        zone = TudlaAccounting.zone(@organization).tzinfo.name
        "to_char(tudla_accounting_entries.posted_at AT TIME ZONE 'UTC' AT TIME ZONE #{quote(zone)}, 'YYYY-MM')"
      end

      # The accounts on a document that aren't its lines: the receivable or payable, and the
      # tax it withholds.
      def not_lines
        scope = Account.where(organization: organization)
        controls = scope.select { |account| account.role_receivable? || account.role_payable? }.flat_map(&:subtree_ids)
        withholding = WithholdingCode.where(organization: organization).pluck(:payable_account_id, :creditable_account_id).flatten.compact
        [ 0, *controls, *withholding ]
      end

      def tax_codes = @tax_codes ||= TaxCode.where(organization: organization).index_by(&:id)
      def tax_summary = @tax_summary ||= TaxReport.call(organization, from: from.from_date, thru: thru.thru_date, basis: :accrual)
      def quote(text) = Detail.connection.quote(text)
      def money(cents) = Money.new(cents, organization.currency)
    end
  end
end
