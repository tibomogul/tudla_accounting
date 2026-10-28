# frozen_string_literal: true

module TudlaAccounting
  class Entry < ApplicationRecord
    belongs_to :organization, polymorphic: true
    belongs_to :source, polymorphic: true, optional: true
    belongs_to :related, polymorphic: true, optional: true

    has_many :details, dependent: :destroy, class_name: "TudlaAccounting::Detail"
    # Receipts and other source documents; see Attachable. A posted entry's are part of its
    # record.
    include Attachable

    REVERSAL_PREFIX = "Reversal of: ".freeze

    # The posted entry that reverses this one; preload it to read many entries' reversals
    # at once (see reversal).
    has_one :posted_reversal, -> { where.not(posted_at: nil).where("particulars LIKE ?", "#{REVERSAL_PREFIX}%") },
            as: :related, class_name: "TudlaAccounting::Entry", inverse_of: false

    accepts_nested_attributes_for :details, allow_destroy: true

    normalizes :reference, with: ->(reference) { reference.strip.presence }

    validates :particulars, presence: true
    validates :reference, length: { maximum: 255 }
    validate :reverse_on_after_date
    validate :has_one_currency?
    validate :has_credit_amounts?
    validate :has_debit_amounts?
    validate :amounts_cancel?
    validate :unchanged_once_posted, on: :update

    before_validation :set_detail_organizations
    before_save :assign_number, if: -> { posted_at.present? && number.nil? }
    before_destroy :ensure_draft, prepend: true
    after_destroy { AuditEvent.record!("entry.deleted", organization: organization, subject: self) }

    def posted?
      posted_at.present?
    end

    def draft?
      !posted?
    end

    # The journal number as shown (the entry_number_format setting), e.g. "#42"; nil
    # until posted.
    def number_label
      TudlaAccounting.configuration.entry_number_label(self)
    end

    # The posted entry that reverses this one, if any: as preloaded (posted_reversal), or
    # else read afresh, so it is never out of date after a reversal.
    def reversal
      association(:posted_reversal).loaded? ? posted_reversal : association(:posted_reversal).scope.first
    end

    # Opened a receivable or payable (an invoice or bill).
    def opens_carrying_amount?
      details.any? { |detail| detail.carrying_amount.present? }
    end

    # Pays a credit back: a refund to a customer, or from a supplier.
    def refund?
      %i[refund supplier_refund].include?(CarryingAmountRole.call(entry: self))
    end

    # A credit applied to receivables or payables (a payment, disbursement or credit note).
    def settlement?
      %i[receipt disbursement credit_note supplier_credit].include?(CarryingAmountRole.call(entry: self))
    end

    # A realized exchange gain or loss posted with a payment.
    def realized_exchange?
      related.is_a?(self.class) && particulars.start_with?(CarryingAmountProcessor::REALIZED_PREFIX)
    end

    # Why reverse! would be refused, or nil if it can be reversed.
    def reversal_blocker
      if draft? then "Only a posted entry can be reversed"
      elsif reversal then "This entry has already been reversed"
      elsif realized_exchange? && related.reversal.nil? && !Allocation.where(realized_entry: self).where.not(reversed_at: nil).exists?
        "Reverse the payment this exchange difference came from instead"
      elsif !refund? && details.any? { |detail| detail.carrying_amount&.charge? && detail.carrying_amount.allocations_to.active.any? }
        "Reverse the payments against it first"
      end
    end

    # Posts an entry on `on` (a date) with every line on the other side, linked back to
    # this one, and returns it. An invoice, bill or payment it was posted for becomes void.
    def reverse!(on:)
      blocker = reversal_blocker
      raise ArgumentError, blocker if blocker

      at = ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone].local(on.year, on.month, on.day)
      transaction do
        reversing = self.class.new(organization: organization, related: self, transacted_at: at,
                                   particulars: "#{REVERSAL_PREFIX}#{particulars}", reference: reference)
        details.each do |detail|
          line = reversing.details.build(account: detail.account, amount_cents: detail.amount_cents, currency: detail.currency,
                                         tally: detail.debit? ? Detail::TALLY_CREDIT : Detail::TALLY_DEBIT,
                                         tax_code: detail.tax_code, tax_role: detail.tax_role, description: detail.description)
          detail.tags.each { |tag| line.tags.build(dimension_value: tag.dimension_value) }
          fx = detail.foreign_exchange
          line.build_foreign_exchange(other_currency: fx.other_currency, other_currency_cents: fx.other_currency_cents, rate: fx.rate) if fx
        end
        reversing.save!
        reversing.post(at)
        undo_carrying_amounts(at)
        source.entry_reversed!(on.to_date) if source.is_a?(Document) || source.is_a?(Payment)
        AuditEvent.record!("entry.reversed", organization: organization, subject: self, details: { reversal_id: reversing.id, on: on.to_date.iso8601 })
        reversing
      end
    end

    def attachment_event_prefix = "entry"
    def attachments_locked? = posted?
    def attachments_locked_label = "a posted entry"

    # Posts every line into the period containing posted_at. An entry with reverse_on (an
    # accrual, say) posts its reversal too, dated that day, in the same transaction: both
    # or neither.
    def post(posted_at)
      raise ArgumentError, "posted_at must be a datetime" unless posted_at.is_a?(Time) || posted_at.is_a?(ActiveSupport::TimeWithZone)
      raise ArgumentError, "entry must be valid" unless valid?

      transaction do
        lock_organization!
        raise ArgumentError, "entry is already posted" if self.class.where(id: id).where.not(posted_at: nil).exists?

        check_reversal_date if reverse_on
        poster = BalancePoster.new(organization)
        details.each { |detail| detail.post(posted_at, poster: poster) }
        update!(posted_at: posted_at)
        CarryingAmountProcessor.call(entry: self)
        AuditEvent.record!("entry.posted", organization: organization, subject: self, details: { posted_at: posted_at.iso8601 })
        reverse!(on: reverse_on) if reverse_on
        true
      end
    end

    # Creates an entry (not posted) from a plain hash, e.g. from another system. With an
    # idempotency_key, an entry already created with that key for the organization is
    # returned instead, so a retried job or replayed webhook doesn't book it twice.
    def self.create_from_ruby_hash(hash)
      key = hash[:idempotency_key].presence
      scope = { organization_type: hash[:organization_type], organization_id: hash[:organization_id] }
      existing = key && find_by(**scope, idempotency_key: key)
      return existing if existing

      entry = build_from_ruby_hash(hash)
      transaction(requires_new: true) { entry.save! }
      entry
    rescue ActiveRecord::RecordNotUnique
      raise unless key

      find_by!(**scope, idempotency_key: key) # created by someone else at the same time
    end

    # The entry create_from_ruby_hash would create, unsaved (valid? says whether it can be),
    # e.g. to check a recurring entry's lines. ArgumentError for what isn't understood.
    def self.build_from_ruby_hash(hash)
      raise ArgumentError, "transacted_at must be a valid ISO 8601 datetime string" unless hash[:transacted_at].is_a?(String)
      begin
        transacted_at = Time.iso8601(hash[:transacted_at])
      rescue ArgumentError
        raise ArgumentError, "transacted_at must be a valid ISO 8601 datetime string"
      end

      if hash[:posted_at].present?
        raise ArgumentError, "posted_at must be a valid ISO 8601 datetime string" unless hash[:posted_at].is_a?(String)
        begin
          posted_at = Time.iso8601(hash[:posted_at])
        rescue ArgumentError
          raise ArgumentError, "posted_at must be a valid ISO 8601 datetime string"
        end
      end

      raise ArgumentError, "particulars must be a string" unless hash[:particulars].is_a?(String)
      raise ArgumentError, "reference must be a string" unless hash[:reference].nil? || hash[:reference].is_a?(String)
      begin
        reverse_on = Date.iso8601(hash[:reverse_on]) if hash[:reverse_on].present?
      rescue ArgumentError, TypeError
        raise ArgumentError, "reverse_on must be a valid ISO 8601 date string"
      end

      raise ArgumentError, "details must be an array" unless hash[:details].is_a?(Array)
      raise ArgumentError, "details must have at least 2 elements" unless hash[:details].length >= 2

      organization = new(organization_type: hash[:organization_type], organization_id: hash[:organization_id]).organization
      default_currency = organization&.currency || TudlaAccounting.configuration.base_currency
      details_attributes = []
      hash[:details].each.with_index(1) do |detail, line|
        raise ArgumentError, "each detail must have an account_code" unless detail[:account_code].present?
        raise ArgumentError, "each detail must have an amount" unless detail[:amount].present?
        raise ArgumentError, "amount must be a string" unless detail[:amount].is_a?(String)
        raise ArgumentError, "description must be a string" unless detail[:description].nil? || detail[:description].is_a?(String)

        account = Account.find_by(code: detail[:account_code], organization_type: hash[:organization_type], organization_id: hash[:organization_id])
        raise ArgumentError, "invalid account_code: #{detail[:account_code]}" unless account
        raise ArgumentError, "account #{detail[:account_code]} is inactive" unless account.active?

        money = parse_money(detail[:amount], default_currency, "line #{line}")

        amount_positive = money.positive?
        amount_cents = money.cents.abs

        tally = if amount_positive
                  account.debit_balance? ? Detail::TALLY_DEBIT : Detail::TALLY_CREDIT
        else
                  account.debit_balance? ? Detail::TALLY_CREDIT : Detail::TALLY_DEBIT
        end

        detail_attributes = {
          account: account,
          tally: tally,
          amount_cents: amount_cents,
          currency: money.currency.iso_code,
          description: detail[:description],
          organization_type: hash[:organization_type],
          organization_id: hash[:organization_id]
        }

        if detail[:fx]
          fx_hash = detail[:fx]
          raise ArgumentError, "fx node must have an other_currency_amount" unless fx_hash[:other_currency_amount].present?
          raise ArgumentError, "fx node must have an fx_rate" unless fx_hash[:fx_rate].present?

          raise ArgumentError, "fx other_currency_amount must be a string" unless fx_hash[:other_currency_amount].is_a?(String)

          other_currency_money = parse_money(fx_hash[:other_currency_amount], default_currency, "line #{line}'s fx amount")
          raise ArgumentError, "fx currency does not match the account currency" unless other_currency_money.currency.iso_code == account.currency

          rate = begin
            AmountParser.decimal(fx_hash[:fx_rate])
          rescue ArgumentError => e
            raise ArgumentError, "line #{line}'s fx_rate: #{e.message}"
          end

          detail_attributes[:foreign_exchange_attributes] = {
            other_currency_cents: other_currency_money.cents.abs, # a magnitude: the line's tally gives the side
            other_currency: other_currency_money.currency.iso_code,
            rate: rate
          }
        end

        detail_attributes[:tags_attributes] = dimension_tags(detail[:dimensions], hash) if detail[:dimensions].present?
        details_attributes << detail_attributes
        add_tax(details_attributes, detail, hash) if detail[:tax_code].present?
      end

      attributes = {
        organization_type: hash[:organization_type],
        organization_id: hash[:organization_id],
        source_type: hash[:source_type],
        source_id: hash[:source_id],
        particulars: hash[:particulars],
        reference: hash[:reference],
        reverse_on: reverse_on,
        transacted_at: transacted_at,
        idempotency_key: hash[:idempotency_key].presence,
        details_attributes: details_attributes
      }
      attributes[:posted_at] = posted_at if hash[:posted_at].present?
      new(attributes)
    end

    # Tags for a line's dimensions, given as dimension code => value code, e.g.
    # { "DEPT" => "SALES", "PROJECT" => "P1" }.
    def self.dimension_tags(dimensions, hash)
      dimensions.map do |dimension_code, value_code|
        dimension = Dimension.find_by(organization_type: hash[:organization_type], organization_id: hash[:organization_id], code: dimension_code.to_s)
        raise ArgumentError, "invalid dimension: #{dimension_code}" unless dimension

        value = dimension.dimension_values.find_by(code: value_code.to_s)
        raise ArgumentError, "invalid #{dimension.name} value: #{value_code}" unless value

        { dimension_value: value }
      end
    end
    private_class_method :dimension_tags

    # A line with a tax_code becomes the base the tax is on, plus a line for the tax on the
    # code's account, on the same side. Its amount excludes the tax (the tax is added), or
    # with tax_inclusive (on the line, or for the whole hash) includes it (it is split).
    #
    # Tax is worked out and posted in the organization's currency: on a line with a foreign
    # amount (fx), it is on the line's converted amount, and the tax line has no foreign
    # amount. Split out of an inclusive line, the line's foreign amount is split the same
    # way, so it too excludes the tax.
    def self.add_tax(details_attributes, detail, hash)
      base = details_attributes.last
      code = TaxCode.find_by(organization_type: hash[:organization_type], organization_id: hash[:organization_id], code: detail[:tax_code])
      raise ArgumentError, "invalid tax_code: #{detail[:tax_code]}" unless code

      tax_account_currency = code.account&.currency.presence
      if tax_account_currency && tax_account_currency != base[:currency]
        raise ArgumentError, "the #{code.code} tax account is held in #{tax_account_currency}; tax is posted in #{base[:currency]}"
      end

      inclusive = detail.fetch(:tax_inclusive, hash[:tax_inclusive]) ? true : false
      tax_cents = code.tax_cents(base[:amount_cents], inclusive: inclusive)
      base.merge!(tax_code: code, tax_role: :base)
      if inclusive
        base[:amount_cents] -= tax_cents
        fx = base[:foreign_exchange_attributes]
        fx[:other_currency_cents] -= code.tax_cents(fx[:other_currency_cents], inclusive: true) if fx
      end
      return unless tax_cents.positive?

      details_attributes << base.slice(:tally, :currency, :organization_type, :organization_id)
        .merge(account: code.account, amount_cents: tax_cents, tax_code: code, tax_role: :tax)
    end
    private_class_method :add_tax

    # Reads "AUD 1,100.00", or "1100.00" in the organization's currency, as AmountParser
    # reads a typed amount: nothing else ("$1,100", "AUD lots", "AUD 1e3", more decimal
    # places than the currency has) is read, and ArgumentError names the line.
    def self.parse_money(text, default_currency, label)
      code, number = text.strip.match(/\A(?:([A-Za-z]{3})\s+)?(.+)\z/).captures
      currency = code ? Money::Currency.find(code) : Money::Currency.wrap(default_currency)
      raise ArgumentError, "#{label}: unknown currency #{code} in amount #{text.inspect}" unless currency

      begin
        cents = AmountParser.cents(number, currency)
      rescue ArgumentError => e
        raise ArgumentError, "#{label}: #{e.message}"
      end
      Money.new(cents, currency)
    end
    private_class_method :parse_money

    private

    # Reversing an invoice or bill closes its receivable or payable; reversing a payment or
    # credit note takes it off what it was applied to (reversing any realized exchange
    # difference) and closes its credit; reversing a refund gives the credit back.
    def undo_carrying_amounts(at)
      CarryingAmountProcessor.new(entry: self).undo_credit(at) if settlement?
      CarryingAmountProcessor.new(entry: self).undo_refund(at) if refund?
      details.filter_map(&:carrying_amount).each(&:recompute!)
    end

    # An entry reverses itself only after its own date, and not if it opens or settles what
    # is owed (its reversal would close the receivable or payable, or take the payment off).
    def reverse_on_after_date
      return unless reverse_on

      if transacted_at && reverse_on <= transacted_at.in_time_zone(TudlaAccounting.configuration.time_zone).to_date
        errors.add(:reverse_on, "must be after the entry's date")
      elsif CarryingAmountRole.call(entry: self)
        errors.add(:reverse_on, "can't be set on an invoice, bill, payment or credit")
      end
    end

    # The reversal needs a month to post into, or posting would fail half way (the
    # transaction undoes it, but this says why). It can't be closed: months close in
    # order, so the entry's own, earlier month would be closed too.
    def check_reversal_date
      raise ArgumentError, "no financial year covers the reversal date" unless Period.leaf_periods_for_date(organization, reverse_on).exists?
    end

    # Lines that will remain once saved (not those being removed while editing).
    def live_details
      details.reject(&:marked_for_destruction?)
    end

    def debit_amounts
      live_details.select(&:debit?)
    end

    def credit_amounts
      live_details.select(&:credit?)
    end

    def has_one_currency?
      errors.add(:base, "All lines must be in the same currency") if live_details.map(&:currency).uniq.count > 1
    end

    # Posted entries are part of the books: correct them by reversing, not editing.
    def unchanged_once_posted
      return unless posted_at_was.present?

      edited = (changed - %w[posted_at related_id related_type updated_at]).any? ||
               details.any? { |detail| detail.new_record? || detail.marked_for_destruction? || detail.changed? }
      errors.add(:base, "A posted entry can't be changed; reverse it instead") if edited
    end

    def ensure_draft
      return if draft?

      errors.add(:base, "A posted entry can't be deleted; reverse it instead")
      throw :abort
    end

    def has_credit_amounts?
      errors.add(:base, "Entry must have at least one credit amount") if credit_amounts.blank?
    end

    def has_debit_amounts?
      errors.add(:base, "Entry must have at least one debit amount") if debit_amounts.blank?
    end

    def amounts_cancel?
      return if live_details.map(&:currency).uniq.count > 1 # can't add up; has_one_currency? reports it

      errors.add(:base, "The credit and debit amounts are not equal") if difference_of_amounts != 0
    end

    def difference_of_amounts
      credit_amount_total = credit_amounts.inject(Money.new(0, organization.currency)) { |sum, credit_amount| sum + credit_amount.amount }
      debit_amount_total = debit_amounts.inject(Money.new(0, organization.currency)) { |sum, debit_amount| sum + debit_amount.amount }
      credit_amount_total - debit_amount_total
    end

    # The next number in the entry's series, when it is posted (or created posted). The
    # sequence's row lock keeps concurrent posts in turn, whatever else they lock.
    def assign_number
      self.number_series = TudlaAccounting.configuration.entry_number_series_for(self)
      self.number = Sequence.next!(organization, "entry:#{number_series}")
    end

    def set_detail_organizations
      details.each do |detail|
        if detail.new_record? && detail.organization.nil?
          detail.organization = organization
        end
      end
    end
  end
end
