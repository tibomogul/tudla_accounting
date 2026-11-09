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
    #
    # PdfMaker.payment_summaries makes a payment summary for each payee from it.
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

      # The amounts behind a payee's row, by date: each payment's (and each void's) WithheldTax.
      def amounts_for(contact)
        rows("from_supplier").where(contact: contact).includes(:payment, :withholding_code).order(:on, :id).to_a
      end

      # The payments to suppliers in the months that were made without all the tax, with
      # why (Payment#not_withheld_reason), by date: for checking the reasons at year end.
      def not_withheld
        @not_withheld ||= Payment.where(organization: organization, kind: "paid", status: "posted", paid_on: from.from_date.to_date..thru.thru_date.to_date)
                                 .where.not(not_withheld_reason: nil).includes(:contact).order(:paid_on, :id).to_a
      end

      # What a payment summary names the payer by: the tax_registration setting's number.
      def payer_registration = TudlaAccounting.configuration.tax_registration_for(organization)

      private

      def rows(direction) = super.where(withholding_code_id: codes.keys)

      def codes
        @codes ||= WithholdingCode.where(organization: organization).on_payment.includes(:payable_account, :creditable_account).index_by(&:id)
      end
    end
  end
end
