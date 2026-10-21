# frozen_string_literal: true

module TudlaAccounting
  # Money received from a customer (kind received) or paid to a supplier (paid), through a
  # bank or cash account, in the organization's currency. Recording one posts its entry
  # straight away, dated paid_on, with the payment as its source: the bank account against
  # the account marked receivable (or payable), opening a credit for the contact, which is
  # applied to the invoices or bills given, as much to each as said. What isn't applied
  # stays as a credit, to apply later from the entry's page.
  #
  #   Payment.record!(organization:, kind: "received", contact: northwind, account: bank,
  #                   paid_on: Date.current, amount_cents: 330_00,
  #                   applications: [ { document: invoice, amount_cents: 330_00 } ])
  #
  # The engine maps its payments to the receipt and disbursement roles itself (see
  # CarryingAmountRole). void! reverses the entry, taking the payment off what it was
  # applied to, and so does reversing the entry itself.
  class Payment < ApplicationRecord
    KINDS = { "received" => { label: "Payment received", role: :receipt, side: :sales }, "paid" => { label: "Payment made", role: :disbursement, side: :purchases } }.freeze
    STANDING = %w[status entry_id voided_on void_reason updated_at].freeze

    belongs_to :organization, polymorphic: true
    belongs_to :contact, class_name: "TudlaAccounting::Contact"
    belongs_to :account, class_name: "TudlaAccounting::Account"
    belongs_to :entry, class_name: "TudlaAccounting::Entry", optional: true

    normalizes :reference, with: ->(reference) { reference.strip.presence }
    normalizes :notes, with: ->(notes) { notes.strip.presence }

    validates :kind, inclusion: { in: KINDS.keys }
    validates :status, inclusion: { in: %w[posted void] }
    validates :paid_on, presence: true
    validates :amount_cents, numericality: { only_integer: true, greater_than: 0, message: "must be more than zero" }
    validates :reference, length: { maximum: 255 }
    validate :contact_fits, on: :create
    validate :account_fits, on: :create
    validate :unchanged_once_recorded, on: :update

    before_destroy { throw :abort } # a payment is voided, never deleted

    scope :received, -> { where(kind: "received") }
    scope :paid, -> { where(kind: "paid") }

    # Records a payment and posts it, applying it to documents ([{ document:, amount_cents: }],
    # each an approved invoice or bill of the contact's), and with bank_line (a statement
    # line on the account) matches it to that line. All or nothing; ArgumentError when it
    # can't be recorded.
    def self.record!(applications: [], bank_line: nil, **attributes)
      payment = new(attributes)
      transaction(requires_new: true) do
        payment.save!
        payment.post!(applications)
        BankReconciler.new(payment.account).match!(bank_line, [ payment.bank_detail ]) if bank_line
      end
      payment
    rescue ActiveRecord::RecordInvalid => e
      raise ArgumentError, e.record.errors.full_messages.to_sentence
    end

    def kind_label = KINDS.fetch(kind)[:label]
    def received? = kind == "received"
    def void? = status == "void"
    def amount = money(amount_cents)

    # The receivable or payable credit it opens, for CarryingAmountProcessor.
    def carrying_amount_role = KINDS.fetch(kind)[:role]
    def carrying_amount_party = contact
    def carrying_amount_due_date = nil

    def bank_detail = entry&.details&.find { |detail| detail.account_id == account_id }
    def credit = entry&.details&.filter_map(&:carrying_amount)&.first

    # What is left to apply.
    def unapplied
      void? ? money(0) : money(-credit.amount_cents)
    end

    # [document or entry, amount, allocation] for each allocation of it, in order.
    def applications
      return [] unless credit

      documents = Document.where(entry_id: credit.allocations_from.joins(to: :detail).select("tudla_accounting_details.entry_id")).index_by(&:entry_id)
      credit.allocations_from.includes(to: { detail: :entry }).order(:allocated_at, :id).map do |allocation|
        entry = allocation.to.detail.entry
        [ documents[entry.id] || entry, money(allocation.amount_cents), allocation ]
      end
    end

    # "Payment from Northwind", "Payment to Cloudware".
    def title
      "Payment #{received? ? 'from' : 'to'} #{contact.name}"
    end

    # Posts its entry and applies it; see record!.
    def post!(applications)
      applications = applications.map { |application| [ application.fetch(:document), application.fetch(:amount_cents).to_i ] }.reject { |_document, cents| cents.zero? }
      check_applications(applications)
      posting = build_entry(applications.map(&:first))
      posting.save!
      at = posting.transacted_at
      posting.post(at)
      update!(entry: posting)
      applications.each do |document, cents|
        Allocator.allocate!(credit, document.entry, amount_cents: cents, at: at)
      end
      AuditEvent.record!("payment.recorded", organization: organization, subject: self, details: { amount_cents: amount_cents, documents: applications.map { |document, _| document.number_label } })
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

    def money(cents) = Money.new(cents, organization&.currency || TudlaAccounting.configuration.base_currency)

    def check_applications(applications)
      wanted = received? ? "sales_invoice" : "bill"
      applications.each do |document, cents|
        unless document.kind == wanted && document.approved? && document.contact_id == contact_id && document.organization == organization
          raise ArgumentError, "#{document.title} isn't an approved #{Document::KINDS[wanted][:label].downcase} of #{contact.name}'s"
        end
        raise ArgumentError, "Apply a positive amount to #{document.number_label}" unless cents.positive?
        raise ArgumentError, "#{Money.new(cents, organization.currency).format} is more than is owed on #{document.number_label}" if cents > document.amount_due.cents
      end
      total = applications.sum(&:last)
      raise ArgumentError, "The payment is #{amount.format} but #{money(total).format} is applied" if total > amount_cents
    end

    # The bank account against the receivable (money in) or payable (money out) account.
    def build_entry(documents)
      control = Account.for_role!(organization, received? ? :receivable : :payable)
      control = control.children.find_by(currency: organization.currency) || control
      at = ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone].local(paid_on.year, paid_on.month, paid_on.day)
      numbers = documents.map(&:number_label)
      posting = Entry.new(organization: organization, source: self, transacted_at: at, reference: reference,
                          particulars: "#{title}#{" (#{numbers.join(', ')})" if numbers.any?}")
      debit, credit_account = received? ? [ account, control ] : [ control, account ]
      posting.details.build(account: debit, tally: Detail::TALLY_DEBIT, amount_cents: amount_cents, currency: organization.currency)
      posting.details.build(account: credit_account, tally: Detail::TALLY_CREDIT, amount_cents: amount_cents, currency: organization.currency)
      posting
    end

    def contact_fits
      return unless contact

      errors.add(:contact, "must belong to the same organization") if contact.organization != organization
      errors.add(:contact, "must be a customer") if kind == "received" && !contact.customer?
      errors.add(:contact, "must be a supplier") if kind == "paid" && !contact.supplier?
    end

    # A bank or cash account of the organization's, in its currency, not receivables or payables.
    def account_fits
      return unless account

      errors.add(:account, "must belong to the same organization") if account.organization != organization
      errors.add(:account, "is inactive") unless account.active?
      errors.add(:account, "must be a bank or cash account") if account.role.in?(%w[receivable payable]) || !account.category.in?([ Account::CATEGORY_ASSET, Account::CATEGORY_LIABILITY ])
      errors.add(:account, "must be held in #{organization.currency}") if organization && account.currency.present? && account.currency != organization.currency
    end

    def unchanged_once_recorded
      errors.add(:base, "A recorded payment can't be changed; void it and record another") if (changed - STANDING).any?
    end
  end
end
