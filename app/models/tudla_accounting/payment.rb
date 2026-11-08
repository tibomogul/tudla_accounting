# frozen_string_literal: true

module TudlaAccounting
  # Money received from a customer (kind received) or paid to a supplier (paid), through a
  # bank or cash account, in the account's currency: the organization's, or for an account
  # held in another, that one at exchange_rate (ForeignCurrency), applied to documents in
  # it. Recording one posts its entry
  # straight away, dated paid_on, with the payment as its source: the bank account against
  # the account marked receivable (or payable), opening a credit for the contact, which is
  # applied to the invoices or bills given, as much to each as said. What isn't applied
  # stays as a credit, to apply later from the entry's page.
  #
  #   Payment.record!(organization:, kind: "received", contact: northwind, account: bank,
  #                   paid_on: Date.current, amount_cents: 330_00,
  #                   applications: [ { document: invoice, amount_cents: 330_00 } ])
  #
  # A refund pays a credit back: money paid back to a customer (kind refund) or back from a
  # supplier (supplier_refund), using up what is left of a payment they made (or we made)
  # or of a credit note (refund_of). Its entry is the bank account against the same
  # receivable or payable account, related to the credit's entry, which the engine uses up.
  #
  #   Payment.record!(organization:, kind: "refund", contact: northwind, account: bank,
  #                   paid_on: Date.current, amount_cents: 50_00, refund_of: credit_note)
  #
  # A customer may withhold tax from what they pay (kind received): withholdings lists
  # each amount, with its code, what the certificate says was withheld and the income it
  # was withheld from (worked out from the rate when not given), in the payment's currency.
  # amount_cents stays the cash received. The tax posts to the code's creditable account,
  # and the receivable is credited with both, which is what can be applied. Each amount
  # keeps a WithheldTax row, for marking its certificate received and for the reports.
  #
  # A payment to a supplier (kind paid) withholds the same way under a code withheld on
  # payment, such as Australia's no-ABN withholding: the tax is worked out from the amount
  # it is withheld from when not given, posts to the code's payable account, and the
  # payable is debited with the cash and the tax.
  #
  #   Payment.record!(organization:, kind: "paid", contact: handyman, account: bank,
  #                   paid_on: Date.current, amount_cents: 530_00,
  #                   withholdings: [ { code: noabn, base_cents: 1_000_00 } ],
  #                   applications: [ { document: bill, amount_cents: 1_000_00 } ])
  #
  #   Payment.record!(organization:, kind: "received", contact: northwind, account: bank,
  #                   paid_on: Date.current, amount_cents: 11_000_00,
  #                   withholdings: [ { code: wc120, withheld_cents: 200_00 } ],
  #                   applications: [ { document: invoice, amount_cents: 11_200_00 } ])
  #
  # The engine maps its payments to the receipt, disbursement, refund and supplier_refund
  # roles itself (see CarryingAmountRole). void! reverses the entry, taking the payment off
  # what it was applied to (a refund off the credit it paid back), and so does reversing
  # the entry itself.
  #
  # A foreign payment posts its amount converted at its rate, the bank line and the
  # receivable or payable line (the account's sub-account in its currency) each with the
  # foreign amount. Applied to an invoice or bill booked at another rate, the difference
  # is posted as a realized exchange gain or loss (see Allocator).
  class Payment < ApplicationRecord
    KINDS = {
      "received" => { label: "Payment received", role: :receipt, side: :sales, money_in: true },
      "paid" => { label: "Payment made", role: :disbursement, side: :purchases, money_in: false },
      "refund" => { label: "Refund to customer", role: :refund, side: :sales, money_in: false },
      "supplier_refund" => { label: "Refund from supplier", role: :supplier_refund, side: :purchases, money_in: true }
    }.freeze
    STANDING = %w[status entry_id voided_on void_reason updated_at].freeze

    include OrganizationOwned
    belongs_to :contact, class_name: "TudlaAccounting::Contact"
    belongs_to :account, class_name: "TudlaAccounting::Account"
    belongs_to :entry, class_name: "TudlaAccounting::Entry", optional: true
    has_many :withheld_taxes, class_name: "TudlaAccounting::WithheldTax", inverse_of: :payment
    include ForeignCurrency

    normalizes :reference, with: ->(reference) { reference.strip.presence }
    normalizes :notes, with: ->(notes) { notes.strip.presence }

    validates :kind, inclusion: { in: KINDS.keys }
    validates :status, inclusion: { in: %w[posted void] }
    validates :paid_on, presence: true
    validates :amount_cents, numericality: { only_integer: true, greater_than: 0, message: "must be more than zero" }
    validates :reference, length: { maximum: 255 }
    validate :contact_fits, on: :create
    validate :account_fits, on: :create
    validate :withholdings_fit, on: :create
    validate(on: :create) { currency_rated(paid_on) }
    validate :unchanged_once_recorded, on: :update

    before_validation(on: :create) do
      self.currency = account&.currency # its account's
      settle_currency(paid_on)
    end
    before_destroy { throw :abort } # a payment is voided, never deleted

    scope :received, -> { where(kind: "received") }
    scope :paid, -> { where(kind: "paid") }

    # Records a payment and posts it, applying it to documents ([{ document:, amount_cents: }],
    # each an approved invoice or bill of the contact's), and with bank_line (a statement
    # line on the account) matches it to that line; a refund names the credit it pays back
    # (refund_of); a customer's payment, or ours to a supplier, can list the tax withheld
    # from it (withholdings). All
    # or nothing; ArgumentError when it can't be recorded.
    def self.record!(applications: [], bank_line: nil, refund_of: nil, withholdings: [], **attributes)
      payment = new(attributes)
      payment.refund_of = refund_of
      payment.withholdings = withholdings
      transaction(requires_new: true) do
        payment.save!
        payment.post!(applications)
        BankReconciler.new(payment.account).match!(bank_line, [ payment.bank_detail ]) if bank_line
      end
      payment
    rescue ActiveRecord::RecordInvalid => e
      raise ArgumentError, e.record.errors.full_messages.to_sentence
    end

    def self.kinds_for(side) = KINDS.select { |_kind, about| about[:side] == side.to_sym }.keys

    # What is left of a credit (a payment or credit note) to refund, in cents. Tax withheld
    # was never received in cash, so it can be applied but not refunded.
    def self.credit_left_cents(credit)
      return credit.amount_due.cents unless credit.is_a?(Payment)

      [ credit.unapplied.cents - credit.withheld_cents, 0 ].max
    end

    attr_writer :refund_of
    attr_reader :withholdings

    # [{ code:, withheld_cents:, base_cents: }], either worked out from the other at the
    # code's rate when not given.
    def withholdings=(given)
      @withholdings = given.map do |withholding|
        code = withholding[:code]
        withheld = withholding[:withheld_cents].presence
        base = withholding[:base_cents].presence
        withheld ||= code.withheld_cents(base) if code && base
        base ||= (BigDecimal(withheld) / code.rate).round.to_i if code && withheld
        { code: code, withheld_cents: withheld, base_cents: base }
      end
      self.withheld_cents = @withholdings.sum { |withholding| withholding[:withheld_cents].to_i }
    end

    def kind_label = KINDS.fetch(kind)[:label]
    def received? = kind == "received"
    def refund? = kind.in?(%w[refund supplier_refund])
    def sales? = KINDS.fetch(kind)[:side] == :sales
    def money_in? = KINDS.fetch(kind)[:money_in]
    def void? = status == "void"
    def amount = money(amount_cents)
    def withheld = money(withheld_cents)
    # The cash and the tax withheld: what it settles of what the contact owes.
    def settled_cents = amount_cents + withheld_cents
    def settled = money(settled_cents)

    # The receivable or payable credit it opens, for CarryingAmountProcessor.
    def carrying_amount_role = KINDS.fetch(kind)[:role]
    def carrying_amount_party = contact
    def carrying_amount_due_date = nil

    def bank_detail = entry&.details&.find { |detail| detail.account_id == account_id }
    def credit = entry&.details&.filter_map(&:carrying_amount)&.first

    # What is left to apply, in its currency (nothing on a refund, which only pays a credit
    # back).
    def unapplied
      return money(0) if void? || refund?

      money(-(foreign? ? credit.forex.other_currency_amount_cents : credit.amount_cents))
    end

    # The payment or credit note a refund paid back.
    def refund_of
      @refund_of || (entry&.related&.source if refund?)
    end

    # [document, payment (a refund) or entry, amount, allocation] for each allocation of
    # it, in order; none on a refund.
    def applications = @applications || self.class.applications_for([ self ]).fetch(self)

    # Loads every payment's applications at once (a page of the API's list, say), so each
    # one's #applications needs no query; reload forgets them. Returns the payments.
    def self.preload_applications(payments)
      payments = payments.to_a
      applications_for(payments).each { |payment, made| payment.instance_variable_set(:@applications, made) }
      payments
    end

    def reload(...)
      @applications = nil
      super
    end

    # Each payment's applications (see #applications), in a few queries however many
    # payments there are: { payment => [[target, amount, allocation], ...] }.
    def self.applications_for(payments)
      ActiveRecord::Associations::Preloader.new(records: payments, associations: { entry: { details: :carrying_amount } }).call
      credits = payments.reject(&:refund?).filter_map { |payment| [ payment, payment.credit ] if payment.credit }.to_h
      allocations = Allocation.where(from: credits.values).includes(to: { detail: :entry }).order(:allocated_at, :id).group_by(&:from_id)
      entry_ids = allocations.values.flatten.map { |allocation| allocation.to.detail.entry_id }
      sources = [ Document, Payment ].flat_map { |model| model.where(entry_id: entry_ids).to_a }.index_by(&:entry_id)
      payments.to_h do |payment|
        made = allocations.fetch(credits[payment]&.id, []).map do |allocation|
          entry = allocation.to.detail.entry
          [ sources[entry.id] || entry, Money.new(payment.foreign? ? allocation.other_currency_cents.to_i : allocation.amount_cents, payment.currency), allocation ]
        end
        [ payment, made ]
      end
    end

    # "Payment from Northwind", "Payment to Cloudware", "Refund to Northwind", "Refund from
    # Cloudware".
    def title
      "#{refund? ? 'Refund' : 'Payment'} #{money_in? ? 'from' : 'to'} #{contact.name}"
    end

    # Posts its entry and applies it; see record!.
    def post!(applications)
      applications = applications.map { |application| [ application.fetch(:document), application.fetch(:amount_cents).to_i ] }.reject { |_document, cents| cents.zero? }
      raise ArgumentError, "Only a refund pays a credit back" if @refund_of && !refund?

      refund? ? check_refund(applications) : check_applications(applications)
      posting = build_entry(applications.map(&:first))
      posting.save!
      at = posting.transacted_at
      posting.post(at)
      update!(entry: posting)
      record_withheld_taxes(posting)
      applications.each do |document, cents|
        Allocator.allocate!(credit, document.entry, **(foreign? ? { other_currency_cents: cents } : { amount_cents: cents }), at: at)
      end
      AuditEvent.record!("payment.recorded", organization: organization, subject: self, details: { amount_cents: amount_cents, documents: applications.map { |document, _| document.number_label },
                                                                                                    refund_of: (refund_of_label if refund?) }.compact)
    end

    # Reverses its entry on `on`, with the reason kept. Refused once the bank statement
    # shows it (unmatch it on the banking page first).
    def void!(on:, reason:)
      reason = reason.to_s.strip
      raise ArgumentError, "This payment is void already" if void?
      raise ArgumentError, "Give a reason for voiding it" if reason.empty?
      raise ArgumentError, "It is matched to a bank statement line; unmatch it on the banking page first" if bank_detail&.bank_match

      transaction do
        entry.reverse!(on: on) # calls entry_reversed!
        update!(void_reason: reason)
        AuditEvent.record!("payment.voided", organization: organization, subject: self, details: { on: on.to_date.iso8601, reason: reason })
      end
      self
    end

    # Its entry was reversed on `on` (by void! or on the entry's own page): it is void.
    def entry_reversed!(on)
      update!(status: "void", voided_on: on)
      WithheldTax.reverse!(entry, on: on)
    end

    private

    def money(cents) = Money.new(cents, currency)
    def text(money) = MoneyFormatter.labelled(money, organization)

    def check_applications(applications)
      wanted = sales? ? "sales_invoice" : "bill"
      applications.each do |document, cents|
        unless document.kind == wanted && document.approved? && document.contact_id == contact_id && document.organization == organization
          raise ArgumentError, "#{document.title} isn't an approved #{Document::KINDS[wanted][:label].downcase} of #{contact.name}'s"
        end
        raise ArgumentError, "#{document.number_label} is in #{document.currency}, and the payment is in #{currency}" if document.currency != currency
        raise ArgumentError, "Apply a positive amount to #{document.number_label}" unless cents.positive?
        raise ArgumentError, "#{text(money(cents))} is more than is owed on #{document.number_label}" if cents > document.amount_due.cents
      end
      total = applications.sum(&:last)
      return unless total > settled_cents

      what = withheld_cents.positive? ? "The payment and the tax withheld come to" : "The payment is"
      raise ArgumentError, "#{what} #{text(settled)} but #{text(money(total))} is applied"
    end

    # A refund pays back a posted payment or approved credit note of the contact's, on the
    # same side, no more than is left of it.
    def check_refund(applications)
      raise ArgumentError, "A refund isn't applied to invoices or bills" if applications.any?

      credit = refund_of or raise ArgumentError, "Choose the payment or credit note it pays back"
      fits = case credit
      when Payment then credit.kind == (sales? ? "received" : "paid") && !credit.void?
      when Document then credit.kind == (sales? ? "sales_credit" : "supplier_credit") && credit.approved?
      end
      unless fits && credit.contact_id == contact_id && credit.organization == organization
        raise ArgumentError, "#{credit.title} isn't a credit of #{contact.name}'s to refund"
      end

      raise ArgumentError, "#{refund_of_label.upcase_first} is in #{credit.currency}, and the refund is in #{currency}" if credit.currency != currency

      left = self.class.credit_left_cents(credit)
      raise ArgumentError, "Only #{text(money(left))} of #{refund_of_label} is left to refund" if amount_cents > left
    end

    def refund_of_label
      refund_of.is_a?(Document) ? refund_of.number_label : "the #{refund_of.title.downcase_first} on #{refund_of.paid_on.strftime('%-d %b %Y')}"
    end

    # The bank account against the receivable (a customer's payment or refund) or payable
    # (a supplier's) account, or its sub-account in a foreign payment's currency, both lines
    # then with the foreign amount; a refund's related to the credit it pays back. Tax
    # withheld is a line of its own (a customer's debited to the creditable account, ours
    # credited to the payable one), and the receivable or payable takes it too.
    def build_entry(documents)
      control = Account.for_role_in_currency!(organization, sales? ? :receivable : :payable, self[:currency])
      at = TudlaAccounting.zone(organization).local(paid_on.year, paid_on.month, paid_on.day)
      numbers = refund? ? [ (refund_of.number_label if refund_of.is_a?(Document)) ].compact : documents.map(&:number_label)
      posting = Entry.new(organization: organization, source: self, transacted_at: at, reference: reference, related: (refund_of.entry if refund?),
                          particulars: "#{title}#{" (#{numbers.join(', ')})" if numbers.any?}")
      debit, credit_account = money_in? ? [ account, control ] : [ control, account ]
      cents = in_base_cents(amount_cents)
      withheld_lines = Array(withholdings).map { |withholding| [ withholding[:code], in_base_cents(withholding[:withheld_cents]) ] }
      [ [ debit, Detail::TALLY_DEBIT ], [ credit_account, Detail::TALLY_CREDIT ] ].each do |line_account, tally|
        on_control = line_account == control
        line = posting.details.build(account: line_account, tally: tally, amount_cents: cents + (on_control ? withheld_lines.sum(&:last) : 0), currency: organization.currency)
        line.build_foreign_exchange(other_currency: currency, other_currency_cents: on_control ? settled_cents : amount_cents, rate: exchange_rate) if foreign?
      end
      withheld_lines.each do |code, withheld|
        account, tally = received? ? [ code.creditable_account, Detail::TALLY_DEBIT ] : [ code.payable_account, Detail::TALLY_CREDIT ]
        posting.details.build(account: account, tally: tally, amount_cents: withheld, currency: organization.currency, description: code.label)
      end
      posting
    end

    def record_withheld_taxes(posting)
      Array(withholdings).each do |withholding|
        WithheldTax.create!(organization: organization, contact: contact, withholding_code: withholding[:code], entry: posting, payment: self, direction: (received? ? "by_customer" : "from_supplier"), on: paid_on,
                            base_cents: in_base_cents(withholding[:base_cents]), withheld_cents: in_base_cents(withholding[:withheld_cents]))
      end
    end

    def contact_fits
      return unless contact

      errors.add(:contact, "must belong to the same organization") if contact.organization != organization
      return unless KINDS.key?(kind)

      errors.add(:contact, "must be a customer") if sales? && !contact.customer?
      errors.add(:contact, "must be a supplier") if !sales? && !contact.supplier?
    end

    # A bank or cash account of the organization's, not receivables or payables.
    def account_fits
      return unless account

      errors.add(:account, "must belong to the same organization") if account.organization != organization
      errors.add(:account, "is inactive") unless account.active?
      control = account.path.any? { |held| held.role.in?(%w[receivable payable]) } # receivables or payables, or beneath them
      errors.add(:account, "must be a bank or cash account") if control || !account.category.in?([ Account::CATEGORY_ASSET, Account::CATEGORY_LIABILITY ])
    end

    def withholdings_fit
      return if withholdings.blank?

      return errors.add(:base, "Only a payment received from a customer or made to a supplier can have tax withheld") unless kind.in?(%w[received paid])

      withholdings.each do |withholding|
        code, withheld, base = withholding.values_at(:code, :withheld_cents, :base_cents)
        next errors.add(:base, "Choose a withholding code for the tax withheld") unless code

        errors.add(:base, "#{code.code} isn't a withholding code of this organization's") if code.organization != organization
        errors.add(:base, "#{code.code} is inactive") unless code.active?
        if received?
          errors.add(:base, "#{code.code} has no account for tax withheld from you") unless code.creditable_account
        elsif !code.on_payment?
          errors.add(:base, "#{code.code} is withheld when the bill is approved, not on the payment")
        end
        errors.add(:base, "The tax withheld under #{code.code} must be more than zero") unless withheld.to_i.positive?
        errors.add(:base, "Give the income #{code.code} was withheld from") unless base.to_i.positive?
        errors.add(:base, "The tax withheld under #{code.code} is more than the income it was withheld from") if base.to_i.positive? && withheld.to_i > base.to_i
      end
    end

    def unchanged_once_recorded
      errors.add(:base, "A recorded payment can't be changed; void it and record another") if (changed - STANDING).any?
    end
  end
end
