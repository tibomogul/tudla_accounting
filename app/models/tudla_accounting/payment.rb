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

    belongs_to :organization, polymorphic: true
    belongs_to :contact, class_name: "TudlaAccounting::Contact"
    belongs_to :account, class_name: "TudlaAccounting::Account"
    belongs_to :entry, class_name: "TudlaAccounting::Entry", optional: true
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
    # (refund_of). All or nothing; ArgumentError when it can't be recorded.
    def self.record!(applications: [], bank_line: nil, refund_of: nil, **attributes)
      payment = new(attributes)
      payment.refund_of = refund_of
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

    # What is left of a credit (a payment or credit note) to apply or refund, in cents.
    def self.credit_left_cents(credit) = credit.is_a?(Payment) ? credit.unapplied.cents : credit.amount_due.cents

    attr_writer :refund_of

    def kind_label = KINDS.fetch(kind)[:label]
    def received? = kind == "received"
    def refund? = kind.in?(%w[refund supplier_refund])
    def sales? = KINDS.fetch(kind)[:side] == :sales
    def money_in? = KINDS.fetch(kind)[:money_in]
    def void? = status == "void"
    def amount = money(amount_cents)

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
    def applications
      return [] if refund? || !credit

      allocations = credit.allocations_from.includes(to: { detail: :entry }).order(:allocated_at, :id).to_a
      entry_ids = allocations.map { |allocation| allocation.to.detail.entry_id }
      sources = [ Document, Payment ].flat_map { |model| model.where(entry_id: entry_ids).to_a }.index_by(&:entry_id)
      allocations.map do |allocation|
        entry = allocation.to.detail.entry
        [ sources[entry.id] || entry, money(foreign? ? allocation.other_currency_cents.to_i : allocation.amount_cents), allocation ]
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
    end

    private

    def money(cents) = Money.new(cents, currency)

    def check_applications(applications)
      wanted = sales? ? "sales_invoice" : "bill"
      applications.each do |document, cents|
        unless document.kind == wanted && document.approved? && document.contact_id == contact_id && document.organization == organization
          raise ArgumentError, "#{document.title} isn't an approved #{Document::KINDS[wanted][:label].downcase} of #{contact.name}'s"
        end
        raise ArgumentError, "#{document.number_label} is in #{document.currency}, and the payment is in #{currency}" if document.currency != currency
        raise ArgumentError, "Apply a positive amount to #{document.number_label}" unless cents.positive?
        raise ArgumentError, "#{money(cents).format} is more than is owed on #{document.number_label}" if cents > document.amount_due.cents
      end
      total = applications.sum(&:last)
      raise ArgumentError, "The payment is #{amount.format} but #{money(total).format} is applied" if total > amount_cents
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
      raise ArgumentError, "Only #{money(left).format} of #{refund_of_label} is left to refund" if amount_cents > left
    end

    def refund_of_label
      refund_of.is_a?(Document) ? refund_of.number_label : "the #{refund_of.title.downcase_first} on #{refund_of.paid_on.strftime('%-d %b %Y')}"
    end

    # The bank account against the receivable (a customer's payment or refund) or payable
    # (a supplier's) account, or its sub-account in a foreign payment's currency, both lines
    # then with the foreign amount; a refund's related to the credit it pays back.
    def build_entry(documents)
      control = Account.for_role_in_currency!(organization, sales? ? :receivable : :payable, self[:currency])
      at = ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone].local(paid_on.year, paid_on.month, paid_on.day)
      numbers = refund? ? [ (refund_of.number_label if refund_of.is_a?(Document)) ].compact : documents.map(&:number_label)
      posting = Entry.new(organization: organization, source: self, transacted_at: at, reference: reference, related: (refund_of.entry if refund?),
                          particulars: "#{title}#{" (#{numbers.join(', ')})" if numbers.any?}")
      debit, credit_account = money_in? ? [ account, control ] : [ control, account ]
      cents = in_base_cents(amount_cents)
      [ [ debit, Detail::TALLY_DEBIT ], [ credit_account, Detail::TALLY_CREDIT ] ].each do |line_account, tally|
        line = posting.details.build(account: line_account, tally: tally, amount_cents: cents, currency: organization.currency)
        line.build_foreign_exchange(other_currency: currency, other_currency_cents: amount_cents, rate: exchange_rate) if foreign?
      end
      posting
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

    def unchanged_once_recorded
      errors.add(:base, "A recorded payment can't be changed; void it and record another") if (changed - STANDING).any?
    end
  end
end
