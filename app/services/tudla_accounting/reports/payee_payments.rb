# frozen_string_literal: true

module TudlaAccounting
  module Reports
    # The tax withheld from suppliers when they were paid (codes withheld on payment, such as
    # Australia's no-ABN withholding), a row per payee over a run of months, normally a
    # financial year: what each was paid before the tax (the gross payment) and the tax
    # withheld, from WithheldTax rows in the organization's currency. It is the list the
    # year-end report to the tax authority and each payee's payment summary are made from.
    #
    # Like Withholding, of which it is the part for those codes, a voided payment counts in
    # the month it was voided, and a payee whose payments net to nothing is left out.
    #
    #   report = PayeePayments.new(organization, from: july, thru: june)
    #   report.payees # => [#<Payee contact codes gross withheld>, ...], by name
    class PayeePayments < Withholding
      Payee = Data.define(:contact, :codes, :gross, :withheld) do
        def missing_address? = contact.address.blank?
      end

      def payees
        @payees ||= qap.group_by(&:contact).filter_map do |contact, rows|
          gross, withheld = rows.sum(&:base), rows.sum(&:withheld)
          Payee.new(contact: contact, codes: rows.map(&:code), gross: gross, withheld: withheld) unless gross.zero? && withheld.zero?
        end
      end

      def total_gross = payees.sum(money(0), &:gross)
      def total_withheld = payees.sum(money(0), &:withheld)
      def missing_addresses = payees.select(&:missing_address?).map { |payee| payee.contact.name }

      private

      def rows(direction) = super.where(withholding_code_id: codes.keys)

      def codes
        @codes ||= WithholdingCode.where(organization: organization).on_payment.includes(:payable_account, :creditable_account).index_by(&:id)
      end
    end
  end
end
