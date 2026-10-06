# frozen_string_literal: true

module TudlaAccounting
  # Converts payments, disbursements and credit notes posted before allocations existed:
  # each gets its credit, applied to the invoice or bill it is related to as far as that
  # was owed (anything over stays as a credit), linked to the realized exchange entry
  # already posted for it, and taken off again from its reversal's date if it was
  # reversed. Nothing is posted. Safe to run again: entries that have their credit
  # already are skipped.
  class AllocationBackfill
    def self.call
      new.call
    end

    def call
      return 0 if TudlaAccounting.configuration.carrying_amount_sources.empty?

      credits.count { |entry| convert(entry) }
    end

    private

    def credits
      roles = TudlaAccounting.configuration.carrying_amount_sources.select { |_type, role| %i[receipt disbursement credit_note supplier_credit].include?(role) }
      Entry.where(source_type: roles.keys).where.not(posted_at: nil).order(:transacted_at, :id)
    end

    def convert(entry)
      return false if entry.details.any? { |detail| detail.carrying_amount.present? }

      Entry.transaction do
        credit = credit_without_side_effects(entry)
        next false unless credit

        charge = related_charge(entry, credit)
        charge&.recompute! # its stored amount still counts every old payment in full
        if charge&.amount_cents&.positive?
          allocation = Allocator.allocate!(credit, charge, at: entry.transacted_at, backfill: true)
          realized = Entry.where(related: entry).where("particulars LIKE ?", "#{CarryingAmountProcessor::REALIZED_PREFIX}%").order(:id).first
          allocation.update!(realized_entry: realized) if realized
          if (reversal = entry.reversal)
            allocation.update!(reversed_at: reversal.transacted_at)
            [ credit, charge ].each(&:recompute!)
          end
        end
        credit.recompute!
        true
      end
    end

    # Its bank balance change happened when it was posted.
    def credit_without_side_effects(entry)
      CarryingAmountProcessor.new(entry: entry, side_effects: false).call
    end

    def related_charge(entry, credit)
      related = entry.related
      return unless related.is_a?(Entry)

      related.details.filter_map(&:carrying_amount).find { |charge| charge.charge? && charge.carrying_amount_type == credit.carrying_amount_type }
    end
  end
end
