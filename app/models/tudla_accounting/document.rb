# frozen_string_literal: true

module TudlaAccounting
  # A sales invoice, a supplier's bill, or a credit note against either (kind), to or from
  # a contact, in the organization's currency or (currency, with exchange_rate: how many of
  # the organization's currency one unit was worth) another. It is drafted line by line (DocumentLine:
  # a description, quantity, unit price, account and tax code), with amounts that exclude
  # the tax or (tax_inclusive) include it.
  #
  # approve! numbers it in its kind's own run (the document_number_format setting) and
  # posts its entry, dated issued_on, with the document as the entry's source (a foreign
  # one's amounts converted at its rate, the total to the receivable or payable account's
  # sub-account in its currency, with its foreign amount): an invoice
  # or bill opens a receivable or payable for the contact, due on due_on; a credit note
  # opens a credit, applied straight away to the invoice or bill it credits
  # (credited_document) as far as that is still owed. The engine maps its documents to
  # those roles itself (see CarryingAmountRole), whatever carrying_amount_sources says.
  #
  # An approved document doesn't change; void! reverses its entry instead, and so does
  # reversing the entry itself. A draft can be deleted.
  class Document < ApplicationRecord
    KINDS = {
      "sales_invoice" => { label: "Invoice", side: :sales, role: :receivable },
      "sales_credit" => { label: "Credit note", side: :sales, role: :credit_note },
      "bill" => { label: "Bill", side: :purchases, role: :payable },
      "supplier_credit" => { label: "Supplier credit", side: :purchases, role: :supplier_credit }
    }.freeze
    STATUSES = %w[draft approved void].freeze
    # The fields an approved document can still change: how it stands, not what it says.
    STANDING = %w[status number number_label entry_id approved_at voided_on void_reason updated_at].freeze

    belongs_to :organization, polymorphic: true
    belongs_to :contact, class_name: "TudlaAccounting::Contact"
    belongs_to :credited_document, class_name: "TudlaAccounting::Document", optional: true
    belongs_to :entry, class_name: "TudlaAccounting::Entry", optional: true
    # The template it was made from, if any (see RecurringInvoice).
    belongs_to :recurring_invoice, class_name: "TudlaAccounting::RecurringInvoice", optional: true, inverse_of: :invoices
    has_many :lines, -> { order(:position, :id) }, class_name: "TudlaAccounting::DocumentLine", dependent: :destroy, inverse_of: :document
    has_many :credit_notes, class_name: "TudlaAccounting::Document", foreign_key: :credited_document_id, inverse_of: :credited_document
    # The supplier's PDF on a bill, a signed order on an invoice; see Attachable. An
    # approved document's are part of its record.
    include Attachable

    accepts_nested_attributes_for :lines, allow_destroy: true

    normalizes :reference, with: ->(reference) { reference.strip.presence }
    normalizes :notes, with: ->(notes) { notes.strip.presence }
    normalizes :currency, with: ->(currency) { currency.strip.upcase.presence }

    validates :kind, inclusion: { in: KINDS.keys }
    validates :status, inclusion: { in: STATUSES }
    validates :issued_on, presence: true
    validates :reference, length: { maximum: 255 }
    validate :contact_fits
    validate :due_after_issue
    validate :credited_document_fits
    validate :currency_fits
    validate :has_lines
    validate :unchanged_once_approved, on: :update

    before_validation :settle_currency, if: :draft?
    before_validation :work_out_totals, if: :draft?
    before_destroy :ensure_draft, prepend: true
    after_create { audit("document.created") }
    after_update { audit("document.updated", changes: saved_changes.except(*STANDING, "created_at")) if (saved_changes.keys - STANDING - %w[created_at]).any? }
    after_destroy { audit("document.deleted") }

    scope :sales, -> { where(kind: %w[sales_invoice sales_credit]) }
    scope :purchases, -> { where(kind: %w[bill supplier_credit]) }
    scope :approved, -> { where(status: "approved") }
    # What is still owed on it (or, on a credit note, left to apply), in cents, as
    # open_cents (and open_base_cents): the receivable or payable its entry opened.
    scope :with_open_cents, lambda {
      # A foreign document's in its currency (open_base_cents in the organization's).
      open = <<~SQL.squish
        FROM tudla_accounting_carrying_amounts c JOIN tudla_accounting_details d ON d.id = c.detail_id
        LEFT JOIN tudla_accounting_carrying_amount_forexes f ON f.carrying_amount_id = c.id WHERE d.entry_id = #{table_name}.entry_id
      SQL
      select("#{table_name}.*",
             "(SELECT ABS(CASE WHEN #{table_name}.currency IS NULL THEN c.amount_cents ELSE COALESCE(f.other_currency_amount_cents, 0) END) #{open}) AS open_cents",
             "(SELECT ABS(c.amount_cents) #{open}) AS open_base_cents")
    }

    def self.kinds_for(side) = KINDS.select { |_kind, about| about[:side] == side.to_sym }.keys

    def kind_label = KINDS.fetch(kind)[:label]
    def side = KINDS.fetch(kind)[:side]
    def sales? = side == :sales
    def purchases? = side == :purchases
    def credit? = kind.in?(%w[sales_credit supplier_credit])
    def draft? = status == "draft"
    def approved? = status == "approved"
    def void? = status == "void"

    # Its currency: the organization's unless it is a foreign document.
    def currency = self[:currency] || organization&.currency || TudlaAccounting.configuration.base_currency
    def foreign? = self[:currency].present?

    # "Invoice INV-0001", or "Draft invoice" before it is numbered.
    def title
      number_label ? "#{kind_label} #{number_label}" : "Draft #{kind_label.downcase}"
    end

    # For the audit trail: "Invoice INV-0001 – Northwind", or before it is numbered "an
    # invoice for Northwind".
    def label
      return "#{title} – #{contact.name}" if number_label

      kind = kind_label.downcase
      "#{kind == 'invoice' ? 'an' : 'a'} #{kind} for #{contact.name}"
    end

    # The receivable or payable it opens, for CarryingAmountProcessor.
    def carrying_amount_role = KINDS.fetch(kind)[:role]
    def carrying_amount_party = contact

    def carrying_amount_due_date
      due_on && zone.local(due_on.year, due_on.month, due_on.day).end_of_day
    end

    def subtotal = money(subtotal_cents)
    def tax = money(tax_cents)
    def total = money(total_cents)

    # What is still owed on an approved invoice or bill, or left to apply of a credit note,
    # in its currency; nothing on a draft or a voided one. From with_open_cents when the
    # query has it.
    def amount_due
      return money(0) unless approved?

      cents = if has_attribute?(:open_cents) then self[:open_cents]
      elsif (open = carrying_amount)
        foreign? ? open.forex&.other_currency_amount_cents : open.amount_cents
      end
      money(cents.to_i.abs)
    end

    # The same in the organization's currency, as the books carry it.
    def amount_due_in_base
      return Money.new(0, organization.currency) unless approved?

      cents = has_attribute?(:open_base_cents) ? self[:open_base_cents] : carrying_amount&.amount_cents
      Money.new(cents.to_i.abs, organization.currency)
    end

    # The total in the organization's currency, as posting converts it: line by line.
    def total_in_base
      Money.new(live_lines.sum { |line| in_base_cents(line.net_cents.to_i) + in_base_cents(line.tax_cents.to_i) }, organization.currency)
    end

    # The receivable or payable its entry opened.
    def carrying_amount = entry&.details&.filter_map(&:carrying_amount)&.first

    # An amount of its currency in the organization's, at its rate.
    def in_base_cents(cents)
      foreign? ? (cents * exchange_rate).round(0, TudlaAccounting.configuration.rounding).to_i : cents
    end

    # draft, void, or for an approved document how far it is paid (or a credit note
    # applied): unpaid, part_paid or paid.
    def payment_status
      return status unless approved?

      due = amount_due.cents
      if due.zero? then "paid"
      elsif due < total_cents then "part_paid"
      else "unpaid"
      end
    end

    def attachment_event_prefix = "document"
    def attachments_locked? = !draft?
    def attachments_locked_label = "an approved document"

    # An approved invoice past its due date with something still owing.
    def overdue?(today)
      kind == "sales_invoice" && approved? && due_on.present? && due_on < today && amount_due.positive?
    end

    # Numbers it and posts its entry, or (ArgumentError) does neither when it can't be
    # posted: nothing to charge, no receivable or payable account, a closed period...
    def approve!(at: Time.current)
      raise ArgumentError, "Only a draft can be approved" unless draft?
      raise ArgumentError, "#{contact.name} is inactive" unless contact.active?
      raise ArgumentError, "The total must be more than zero" unless total_cents.positive?

      transaction(requires_new: true) do # a savepoint, so a failure leaves a caller's transaction as it was
        lock!
        self.number = Sequence.next!(organization, "document:#{kind}")
        self.number_label = TudlaAccounting.configuration.document_number_label(self)
        posting = build_entry
        posting.save!
        posting.post(posting.transacted_at)
        update!(status: "approved", entry: posting, approved_at: at)
        audit("document.approved", entry_id: posting.id)
      end
      self
    rescue ActiveRecord::RecordInvalid, ArgumentError => e
      restore_attributes(%w[number number_label status entry_id approved_at])
      raise e if e.is_a?(ArgumentError)

      raise ArgumentError, e.record.errors.full_messages.to_sentence
    end

    # Reverses its entry on `on`, with the reason kept. ArgumentError when it can't be
    # (payments or credit notes still applied to it, a closed period...).
    def void!(on:, reason:)
      reason = reason.to_s.strip
      raise ArgumentError, "Only an approved document can be voided" unless approved?
      raise ArgumentError, "Give a reason for voiding it" if reason.empty?

      transaction do
        entry.reverse!(on: on) # calls entry_reversed!
        update!(void_reason: reason)
        audit("document.voided", on: on.to_date.iso8601, reason: reason)
      end
      self
    end

    # Its entry was reversed on `on` (by void! or on the entry's own page): it is void.
    def entry_reversed!(on)
      update!(status: "void", voided_on: on)
    end

    private

    def zone = ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone]
    def money(cents) = Money.new(cents, currency)

    def live_lines = lines.reject(&:marked_for_destruction?)

    def work_out_totals
      live_lines.each { |line| line.work_out(tax_inclusive?) }
      self.subtotal_cents = live_lines.sum(&:net_cents)
      self.tax_cents = live_lines.sum { |line| line.tax_cents.to_i }
      self.total_cents = subtotal_cents + tax_cents
    end

    # The entry: the total to the receivable or payable account, and each line's net amount
    # (tagged with the line's dimension values) and tax to its accounts on the other side
    # (the other way round for a credit note). A foreign document's amounts are converted
    # line by line, the total being their sum, and its total goes to the account's
    # sub-account in its currency with its foreign amount.
    def build_entry
      control = Account.for_role_in_currency!(organization, sales? ? :receivable : :payable, self[:currency])
      charge = sales? != credit? ? Detail::TALLY_DEBIT : Detail::TALLY_CREDIT
      other = charge == Detail::TALLY_DEBIT ? Detail::TALLY_CREDIT : Detail::TALLY_DEBIT
      at = zone.local(issued_on.year, issued_on.month, issued_on.day)
      posting = Entry.new(organization: organization, source: self, transacted_at: at, reference: number_label,
                          particulars: "#{title} – #{contact.name}#{" (their #{reference})" if purchases? && reference}",
                          related: credited_document&.entry)
      line = ->(account, tally, cents, **extra) { posting.details.build(account: account, tally: tally, amount_cents: cents, currency: organization.currency, **extra) }
      total = line.call(control, charge, 0)
      total.build_foreign_exchange(other_currency: currency, other_currency_cents: total_cents, rate: exchange_rate) if foreign?
      live_lines.each do |item|
        net_cents, tax_cents = in_base_cents(item.net_cents), in_base_cents(item.tax_cents.to_i)
        if net_cents.positive?
          net = line.call(item.account, other, net_cents, description: item.description, **({ tax_code: item.tax_code, tax_role: :base } if item.tax_code).to_h)
          item.dimension_values.each { |value| net.tags.build(dimension_value: value) }
        end
        line.call(item.tax_code.account, other, tax_cents, description: item.description, tax_code: item.tax_code, tax_role: :tax) if tax_cents.positive?
      end
      total.amount_cents = posting.details.sum(&:amount_cents)
      posting
    end

    # The organization's own currency is kept as none; a foreign one without a rate gets
    # the day's from ForexRateRetriever, when it has one.
    def settle_currency
      self.currency = nil if self[:currency] == organization&.currency
      return self.exchange_rate = nil unless foreign?
      return if exchange_rate || issued_on.nil? || !Money::Currency.find(self[:currency])

      self.exchange_rate = ForexRateRetriever.call(from: currency, to: organization.currency, date: issued_on)
    rescue ForexRateRetriever::RateNotFound
      nil
    end

    def currency_fits
      return unless foreign?
      return errors.add(:currency, "is not a known currency code") unless Money::Currency.find(self[:currency])

      if exchange_rate.nil?
        errors.add(:exchange_rate, "is needed: no #{currency} rate was found for #{issued_on&.strftime('%-d %b %Y')}")
      elsif !exchange_rate.positive?
        errors.add(:exchange_rate, "must be more than zero")
      end
    end

    def contact_fits
      return unless contact

      errors.add(:contact, "must belong to the same organization") if contact.organization != organization
      if KINDS.key?(kind)
        errors.add(:contact, "must be a customer") if sales? && !contact.customer?
        errors.add(:contact, "must be a supplier") if purchases? && !contact.supplier?
      end
      errors.add(:contact, "is inactive") if draft? && !contact.active? && (new_record? || will_save_change_to_contact_id?)
    end

    def due_after_issue
      errors.add(:due_on, "must be on or after the date") if due_on && issued_on && due_on < issued_on
    end

    # A credit note credits an approved invoice (a supplier credit, a bill) to the same contact.
    def credited_document_fits
      return unless credited_document
      return errors.add(:credited_document, "can only be given for a credit note") unless credit?

      wanted = sales? ? "sales_invoice" : "bill"
      errors.add(:credited_document, "must be an approved #{KINDS[wanted][:label].downcase}") unless credited_document.kind == wanted && !credited_document.draft?
      errors.add(:credited_document, "must be to the same contact") unless credited_document.contact_id == contact_id
      errors.add(:credited_document, "is in #{credited_document.currency}; a credit note for it must be too") unless credited_document.currency == currency
    end

    def has_lines
      errors.add(:base, "Add at least one line") if live_lines.empty?
    end

    def unchanged_once_approved
      return if status_was == "draft"

      changed_fields = changed - STANDING
      errors.add(:base, "An approved document can't be changed; void it and issue another") if changed_fields.any? || lines.any?(&:changed_for_autosave?)
    end

    def ensure_draft
      return if draft?

      errors.add(:base, "Only a draft can be deleted; void an approved document instead")
      throw :abort
    end

    def audit(action, **details)
      AuditEvent.record!(action, organization: organization, subject: self, details: details)
    end
  end
end
