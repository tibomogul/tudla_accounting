# frozen_string_literal: true

module TudlaAccounting
  # Whether tax is withheld from a payment to a supplier under its code withheld on payment
  # (Contact#payment_withholding_code, such as Australia's no-ABN withholding), from how
  # much, and why not, for what isn't:
  #
  # - a supplier with an exemption (Contact#withholding_exemption) has nothing withheld;
  # - a bill whose supply is the code's exempt_up_to or less (its total before tax, in the
  #   organization's currency at the bill's rate) isn't withheld from, nor is an amount
  #   applied to no bill that is that or less (at exchange_rate, the payment's, when it is
  #   in another currency).
  #
  # The payment form, pay runs, bank lines and Payment.record! (for the reason a payment
  # made without the tax keeps) all decide through it.
  #
  #   decision = PaymentWithholding.new(gardener, [ { document: bill, amount_cents: 60_00 } ])
  #   decision.code       # => the code to withhold under, or nil when nothing is withheld
  #   decision.base_cents # => what it is withheld from: what is paid of the bills over the limit
  #   decision.reason     # => why some or all of it isn't withheld from, or nil
  class PaymentWithholding
    attr_reader :code, :base_cents, :reason

    def initialize(supplier, applications = [], unapplied_cents: 0, exchange_rate: nil)
      @supplier = supplier
      @base_cents = 0
      code = supplier&.payment_withholding_code or return
      return @reason = supplier.withholding_exemption_reason if supplier.withholding_exemption

      @limit = code.exempt_up_to_cents
      small = applications.select { |application| small_supply?(application.fetch(:document)) }
      @base_cents = (applications - small).sum { |application| application.fetch(:amount_cents) }
      small_unapplied = unapplied_cents.positive? && @limit && in_base(unapplied_cents, exchange_rate) <= @limit
      @base_cents += unapplied_cents if unapplied_cents.positive? && !small_unapplied
      @reason = small_reason(small.map { |application| application.fetch(:document) }, small_unapplied)
      @code = code if @base_cents.positive?
    end

    private

    def small_supply?(document) = @limit && in_base(document.subtotal_cents, document.exchange_rate) <= @limit

    def in_base(cents, rate) = rate ? (BigDecimal(cents) * rate).round.to_i : cents

    def small_reason(documents, unapplied)
      return if documents.empty? && !unapplied

      limit = MoneyFormatter.labelled(Money.new(@limit, @supplier.organization.currency), @supplier.organization)
      parts = [ ("#{documents.many? ? 'the supplies' : 'the supply'} on #{documents.map(&:number_label).to_sentence}" if documents.any?),
                ("what was applied to no bill" if unapplied) ].compact
      "#{parts.to_sentence.upcase_first} #{parts.many? || documents.many? ? 'are each' : 'is'} #{limit} or less before tax"
    end
  end
end
