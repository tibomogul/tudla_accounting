# frozen_string_literal: true

module TudlaAccounting
  module Reports
    # What each supplier's tax certificate (BIR Form 2307) says for three months: the income
    # by code and month, and the tax withheld, from WithheldTax rows in the organization's
    # currency. Like the withholding reports, a reversal or supplier credit counts in the
    # month it was dated, which can make a line negative, and a code that nets to nothing
    # is left out.
    #
    # The form has ten lines, so a supplier with more codes takes more sheets, each with its
    # own totals.
    #
    #   report = SupplierCertificates.new(organization, quarter)
    #   report.certificates # => [#<Certificate contact lines>, ...], by supplier name
    #   report.months       # => the first day of each of the three months
    class SupplierCertificates
      LINES_PER_SHEET = 10
      TIN_GROUPS = [ 3, 3, 3, 5 ].freeze

      Line = Data.define(:code, :months, :withheld) do
        def total = months.sum
      end
      Sheet = Data.define(:contact, :lines) do
        def month_total(index) = lines.sum { |line| line.months[index] }
        def total = lines.sum(&:total)
        def withheld = lines.sum(&:withheld)
      end
      Certificate = Data.define(:contact, :lines) do
        def total = lines.sum(&:total)
        def withheld = lines.sum(&:withheld)
        def negative? = lines.any? { |line| line.withheld.negative? || line.total.negative? }
        def sheets = lines.each_slice(LINES_PER_SHEET).map { |held| Sheet.new(contact: contact, lines: held) }
      end

      # A tax number's digits in the form's boxes, or nil when they wouldn't fit them (a
      # foreign number, say), to be written as they are.
      def self.tin_boxes(tax_number)
        text = tax_number.to_s.strip
        return if text.match?(/[^\d\s-]/) || text.delete("^0-9").size > TIN_GROUPS.sum

        digits = text.delete("^0-9")
        TIN_GROUPS.map { |size| digits.slice!(0, size).to_s.ljust(size).chars }
      end

      attr_reader :organization, :quarter

      def initialize(organization, quarter)
        @organization = organization
        @quarter = quarter
      end

      def months = (0..2).map { |index| quarter.from.beginning_of_month >> index }

      def certificates
        @certificates ||= grouped.map { |contact_id, held| Certificate.new(contact: contacts.fetch(contact_id), lines: lines(held)) }.select { |certificate| certificate.lines.any? }
                                 .sort_by { |certificate| certificate.contact.name.downcase }
      end

      def waiting_for_tin = certificates.select { |certificate| certificate.contact.tax_number.blank? }

      # What the withholding_agent setting hasn't given that the form needs.
      def missing_agent_details
        agent = TudlaAccounting.configuration.withholding_agent_for(organization)
        { tin: "TIN", address: "address", zip: "ZIP code", signatory_name: "signatory's name", signatory_title: "signatory's title", signatory_tin: "signatory's TIN" }
          .filter_map { |key, label| label if agent[key].blank? }
      end

      private

      def grouped
        month = Arel.sql("to_char(#{WithheldTax.quoted_table_name}.on, 'YYYY-MM')")
        @grouped ||= WithheldTax.where(organization: organization, direction: "from_supplier", on: quarter.range)
                                .group(:contact_id, :withholding_code_id, month).pluck(:contact_id, :withholding_code_id, month, Arel.sql("SUM(base_cents)"), Arel.sql("SUM(withheld_cents)"))
                                .group_by(&:first)
      end

      def lines(held)
        held.group_by(&:second).filter_map do |code_id, rows|
          next if rows.sum { |row| row[3] }.zero? && rows.sum { |row| row[4] }.zero?

          base = rows.to_h { |row| [ row[2], row[3] ] }
          Line.new(code: codes.fetch(code_id), months: months.map { |month| money(base.fetch(month.strftime("%Y-%m"), 0)) }, withheld: money(rows.sum { |row| row[4] }))
        end.sort_by { |line| line.code.code }
      end

      def contacts = @contacts ||= Contact.where(id: grouped.keys).index_by(&:id)
      def codes = @codes ||= WithholdingCode.where(organization: organization).index_by(&:id)
      def money(cents) = Money.new(cents, organization.currency)
    end
  end
end
