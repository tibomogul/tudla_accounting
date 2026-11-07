# frozen_string_literal: true

module TudlaAccounting
  module Reports
    # What was paid over a run of months (normally a financial year) to the contacts marked
    # taxable_payments, for a taxable payments report such as Australia's TPAR: a row per
    # payee with the gross paid (cash and any tax withheld, GST included), the GST in it and
    # the tax withheld, in the organization's currency.
    #
    # A payment counts when it was made. Its GST is each bill's GST in proportion to the part
    # of the bill it paid, at the bill's exchange rate; a payment, or part of one, applied to
    # no bill has no GST, and its payee is flagged. A refund from the supplier takes off what
    # it refunded, with the GST of the supplier credit it paid back (none for an overpayment).
    # A voided payment or refund counts against the months it was voided in, so a year
    # already reported stays as it was.
    #
    #   report = TaxablePayments.new(organization, from: july, thru: june)
    #   report.payees # => [#<Payee contact payments gross gst withheld unapplied>, ...], by name
    class TaxablePayments
      Payee = Data.define(:contact, :payments, :gross, :gst, :withheld, :unapplied) do
        def missing_tax_number? = contact.tax_number.blank?
        def missing_address? = contact.address.blank?
      end
      Amount = Data.define(:gross, :gst, :withheld, :unapplied)

      attr_reader :organization, :from, :thru

      def initialize(organization, from:, thru:)
        @organization = organization
        @from = from
        @thru = thru
      end

      def any_payees_marked? = Contact.where(organization: organization, taxable_payments: true).exists?

      def payees
        @payees ||= signed_payments.group_by { |payment, _sign| payment.contact }.filter_map do |contact, held|
          amounts = held.map { |payment, sign| amount(payment, sign) }
          gross = money(amounts.sum(&:gross))
          next if gross.zero? && amounts.sum(&:withheld).zero?

          Payee.new(contact: contact, payments: held.sum { |payment, sign| payment.refund? ? 0 : sign }, gross: gross, gst: money(amounts.sum(&:gst)), withheld: money(amounts.sum(&:withheld)), unapplied: money(amounts.sum(&:unapplied)))
        end.sort_by { |payee| [ payee.contact.name.downcase, payee.contact.id ] }
      end

      def total(attribute) = payees.sum(money(0), &attribute)

      private

      def range = from.from_date.to_date..thru.thru_date.to_date

      # Each payment or refund made in the months, and each voided in them, with its sign:
      # +1 for a payment made or a refund voided, -1 for the opposite.
      def signed_payments
        @signed_payments ||= begin
          scope = Payment.where(organization: organization, kind: %w[paid supplier_refund], contact: Contact.where(organization: organization, taxable_payments: true))
                         .includes(:contact, :organization, entry: { related: :source })
          made = scope.where(paid_on: range).map { |payment| [ payment, payment.refund? ? -1 : 1 ] }
          made + scope.where(status: "void", voided_on: range).map { |payment| [ payment, payment.refund? ? 1 : -1 ] }
        end
      end

      def applications = @applications ||= Payment.applications_for(signed_payments.map(&:first).uniq)

      # A payment's amounts in the organization's currency, signed.
      def amount(payment, sign)
        return refund_amount(payment, sign) if payment.refund?

        applied = applied_bills(payment)
        gst = applied.sum(0) { |document, paid, _allocation| base(document, share(document.tax_cents, paid.cents, document.payable_cents)) }
        unapplied = payment.settled_cents - applied.sum { |_document, paid, _allocation| paid.cents }
        Amount.new(gross: sign * base(payment, payment.settled_cents), gst: sign * gst, withheld: sign * base(payment, payment.withheld_cents),
                   unapplied: sign * base(payment, [ unapplied, 0 ].max))
      end

      # A refund's amounts: the cash back, and the GST of the supplier credit it paid back.
      def refund_amount(payment, sign)
        credit = payment.refund_of
        gst = credit.is_a?(Document) ? base(credit, share(credit.tax_cents, payment.amount_cents, credit.payable_cents)) : 0
        Amount.new(gross: sign * base(payment, payment.amount_cents), gst: sign * gst, withheld: 0, unapplied: 0)
      end

      # part of whole's cents in proportion, unrounded.
      def share(cents, part, whole) = whole.zero? ? 0 : BigDecimal(cents) * part / whole

      # The bills a payment paid, with how much of each: its allocations still in force, or
      # for a void payment, those its voiding reversed.
      def applied_bills(payment)
        made = applications.fetch(payment)
        if payment.void?
          voided_at = made.filter_map { |_target, _paid, allocation| allocation.reversed_at }.max
          made = made.select { |_target, _paid, allocation| allocation.reversed_at == voided_at }
        else
          made = made.select { |_target, _paid, allocation| allocation.active? }
        end
        made.select { |target, _paid, _allocation| target.is_a?(Document) }
      end

      # cents in a payment's or document's currency, in the organization's at its rate, rounded.
      def base(record, cents)
        value = record.exchange_rate ? BigDecimal(cents) * record.exchange_rate : BigDecimal(cents)
        value.round(0, TudlaAccounting.configuration.rounding_for(@organization)).to_i
      end

      def money(cents) = Money.new(cents, organization.currency)
    end
  end
end
