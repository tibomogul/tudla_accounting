# frozen_string_literal: true

module TudlaAccounting
  # Applies credits (payments, disbursements and credit notes) to what is owed on invoices
  # and bills, and takes them off again:
  #
  #   Allocator.allocate!(payment, invoice)                          # as much as both allow
  #   Allocator.allocate!(payment, invoice, amount_cents: 200_00)    # part of it
  #   Allocator.allocate!(payment, invoice, other_currency_cents: 60_00) # 60.00 of a foreign amount
  #   Allocator.allocate_oldest_first!(payment)                      # to the party's charges, oldest due first
  #   Allocator.unallocate!(allocation, at: Time.current)
  #
  # Each side is an Entry or its CarryingAmount. Both must be for the same party, the
  # credit can't use more than it has left, and the charge can't take more than is owed.
  # A foreign-currency credit applied to a foreign-currency charge settles the foreign
  # amount at the rate the charge was booked at, and the difference from the credit's own
  # value for it is posted as a realized exchange gain or loss (when a
  # realized_fx_gain_account_code is set).
  class Allocator
    class << self
      # backfill: true records the allocation only (no closed-period check, realized
      # entry or audit event); see AllocationBackfill.
      def allocate!(from, to, amount_cents: nil, other_currency_cents: nil, at: Time.current, backfill: false)
        new(at: at).allocate(carrying_amount(from), carrying_amount(to), amount_cents: amount_cents,
                             other_currency_cents: other_currency_cents, backfill: backfill)
      end

      def allocate_oldest_first!(from, at: Time.current)
        credit = carrying_amount(from)
        new(at: at).allocate_oldest_first(credit)
      end

      def unallocate!(allocation, at: Time.current)
        new(at: at).unallocate(allocation)
      end

      # The open charges a credit could be applied to: the same party's, in the same
      # ledger, with something still owed, oldest due first.
      def open_charges(from)
        credit = carrying_amount(from)
        CarryingAmount.joins(detail: :entry).includes(:forex, detail: :entry)
          .where(carrying_amount_type: credit.carrying_amount_type, related_party: credit.related_party,
                 tudla_accounting_details: { organization_type: credit.detail.organization_type, organization_id: credit.detail.organization_id })
          .where("tudla_accounting_carrying_amounts.amount_cents > 0")
          .order(Arel.sql("tudla_accounting_carrying_amounts.due_date ASC NULLS LAST"), "tudla_accounting_entries.transacted_at", :id)
          .select(&:charge?)
      end

      def carrying_amount(record)
        return record if record.is_a?(CarryingAmount)

        record.details.filter_map(&:carrying_amount).first or raise ArgumentError, "#{record.particulars} has no receivable or payable to apply"
      end
    end

    def initialize(at:)
      @at = at
    end

    def allocate(credit, charge, amount_cents: nil, other_currency_cents: nil, backfill: false)
      check_pair(credit, charge, backfill: backfill)
      ActiveRecord::Base.transaction do
        lock_and_check_period(credit) unless backfill
        cash, foreign = amounts(credit.reload, charge.reload, amount_cents, other_currency_cents)
        allocation = Allocation.create!(organization: credit.detail.organization, from: credit, to: charge, amount_cents: cash,
                                        other_currency_cents: foreign, allocated_at: @at)
        if !backfill && charge.forex && foreign
          realized = charge.settle(charge.amount_cents, charge.forex.other_currency_amount_cents, cash, foreign)[:realized_cents]
          allocation.update!(realized_entry: post_realized(credit, charge, realized))
        end
        [ credit, charge ].each(&:recompute!)
        unless backfill
          AuditEvent.record!("allocation.created", organization: allocation.organization, subject: allocation,
                             details: { amount_cents: cash, other_currency_cents: foreign }.compact)
        end
        allocation
      end
    end

    def allocate_oldest_first(credit)
      raise ArgumentError, "Only a payment or credit note can be applied" unless credit.credit?

      self.class.open_charges(credit).each_with_object([]) do |charge, made|
        break made unless credit.reload.amount_cents.negative?
        next if charge.forex && credit.forex && charge.forex.other_currency != credit.forex.other_currency

        made << allocate(credit, charge)
      end
    end

    def unallocate(allocation)
      raise ArgumentError, "This allocation has already been taken off" unless allocation.active?

      ActiveRecord::Base.transaction do
        lock_and_check_period(allocation.from)
        allocation.update!(reversed_at: @at)
        realized = allocation.realized_entry
        realized.reverse!(on: @at.to_date) if realized && !realized.reversal
        [ allocation.from, allocation.to ].each(&:recompute!)
        AuditEvent.record!("allocation.reversed", organization: allocation.organization, subject: allocation)
        allocation
      end
    end

    private

    # A backfill records what happened before a reversal, so reversed entries are fine.
    def check_pair(credit, charge, backfill: false)
      raise ArgumentError, "Only a payment or credit note can be applied" unless credit.credit?
      raise ArgumentError, "A payment or credit note can only be applied to an invoice or bill" unless charge.charge?
      raise ArgumentError, "Both must be receivables or both payables" unless credit.carrying_amount_type == charge.carrying_amount_type
      raise ArgumentError, "Both must belong to the same organization" unless credit.detail.organization == charge.detail.organization
      raise ArgumentError, "Both must be for the same customer or supplier" unless credit.related_party == charge.related_party
      raise ArgumentError, "A reversed entry can't be applied" if !backfill && [ credit, charge ].any? { |side| side.detail.entry.reversal }
      if credit.forex && charge.forex && credit.forex.other_currency != charge.forex.other_currency
        raise ArgumentError, "The payment is in #{credit.forex.other_currency} but the amount owed is in #{charge.forex.other_currency}"
      end
    end

    # [credit used (organization currency), foreign amount applied or nil]
    def amounts(credit, charge, amount_cents, other_currency_cents)
      available = -credit.amount_cents
      owed = charge.amount_cents
      raise ArgumentError, "Nothing is left to apply" unless available.positive?
      raise ArgumentError, "Nothing is owed on it" unless owed.positive?

      if credit.forex && charge.forex
        available_foreign = -credit.forex.other_currency_amount_cents
        foreign = other_currency_cents || [ available_foreign, charge.forex.other_currency_amount_cents ].min
        raise ArgumentError, "Apply more than nothing" unless foreign.positive?
        raise ArgumentError, "That is more than is left to apply" if foreign > available_foreign
        raise ArgumentError, "That is more than is owed" if foreign > charge.forex.other_currency_amount_cents

        [ share(available, foreign, available_foreign), foreign ]
      else
        cash = amount_cents || [ available, owed ].min
        raise ArgumentError, "Apply more than nothing" unless cash.positive?
        raise ArgumentError, "That is more than is left to apply" if cash > available
        raise ArgumentError, "That is more than is owed" if cash > owed

        # A foreign credit applied to a charge in the organization's currency uses its
        # foreign amount in proportion.
        [ cash, credit.forex && share(-credit.forex.other_currency_amount_cents, cash, available) ]
      end
    end

    # part / whole of total, all of it when part is the whole.
    def share(total, part, whole)
      part == whole ? total : (BigDecimal(total) * part / whole).round.to_i
    end

    # Takes the posting lock, and refuses a date in a closed period (allocations change
    # what was owed as at that date).
    def lock_and_check_period(credit)
      organization = credit.detail.organization
      organization.class.lock.find(organization.id)
      period = Period.leaf_periods_for_date(organization, @at).first
      raise ArgumentError, "#{period.label} is closed" if period&.closed?
    end

    # The credit's line moved the receivable/payable by the credit's own value; move it by
    # the difference so it reflects the book value settled, and recognize the difference.
    # Without a realized_fx_gain_account_code nothing is posted (and the difference stays on
    # the receivable/payable account).
    def post_realized(credit, charge, difference_cents)
      return if difference_cents.zero?

      gain_account_code = TudlaAccounting.configuration.realized_fx_gain_account_code
      charge_entry = charge.detail.entry
      if gain_account_code.blank?
        Rails.logger.warn("TudlaAccounting: realized_fx_gain_account_code is not set; exchange difference on #{charge_entry.particulars} not posted")
        return
      end

      credit_entry = credit.detail.entry
      currency = credit.detail.currency
      difference = Money.new(difference_cents, currency)
      gain = charge.payable? ? -difference : difference # paying more for a liability is a loss
      entry = Entry.create_from_ruby_hash(
        organization_type: credit_entry.organization_type, organization_id: credit_entry.organization_id,
        particulars: "#{CarryingAmountProcessor::REALIZED_PREFIX}#{gain.positive? ? 'gain' : 'loss'} on #{charge_entry.particulars}",
        transacted_at: @at.iso8601,
        details: [ { account_code: credit.detail.account.code, amount: "#{currency} #{difference}" },
                   { account_code: gain_account_code, amount: "#{currency} #{gain}" } ]
      )
      entry.update!(related: credit_entry) # no source, so posting it opens or settles nothing
      entry.post(entry.transacted_at)
      entry
    end
  end
end
