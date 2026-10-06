# frozen_string_literal: true

module TudlaAccounting
  class Period < ApplicationRecord
    include DatetimeRange
    has_ancestry orphan_strategy: :restrict, cache_depth: true, counter_cache: true, ancestry_format: :materialized_path2
    belongs_to :organization, polymorphic: true

    validates :from_date, :thru_date, presence: true
    validate :check_period_length

    has_many :balances, dependent: :destroy, class_name: "TudlaAccounting::Balance"

    # Records are equal by identity, as ActiveRecord defines it, not by their dates as
    # DatetimeRange's Comparable would make them (two organizations' 2026 are different
    # periods). Use equals? to compare dates.
    def ==(other)
      ActiveRecord::Core.instance_method(:==).bind_call(self, other)
    end
    alias eql? ==

    def self.ancestry_check(period)
      return false if period.parent

      period.partitioned_by_children?
    end

    def partitioned_by_children?
      return true if children.blank?

      children.each do |child|
        return false unless child.partitioned_by_children?
      end
      partitioned_by?(children)
    end

    # Periods containing a moment in time. A plain Date means that day in the
    # configured time zone (the zone PeriodCreator builds periods in), not Rails'
    # Time.zone, which may differ.
    # A year (or any period) can be removed while nothing has been posted in it.
    def deletable?
      TudlaAccounting::Balance.where(period_id: subtree_ids).none?
    end

    # Removes the period and everything inside it, deepest first.
    def destroy_with_subtree!
      raise ActiveRecord::RecordNotDestroyed.new("Only a period with no balances can be deleted", self) unless deletable?

      transaction do
        subtree.sort_by(&:depth).reverse_each(&:destroy!)
        AuditEvent.record!("period.deleted", organization: organization, subject: self)
      end
    end

    # "2026" for a calendar year, otherwise its date range; "Mar 2026" for a month.
    def label
      from = from_date.to_date
      thru = thru_date.to_date
      if from == from.beginning_of_year && thru == from.end_of_year
        from.year.to_s
      elsif from == from.beginning_of_month && thru == from.end_of_month
        from.strftime("%b %Y")
      else
        "#{from.strftime('%-d %b %Y')} – #{thru.strftime('%-d %b %Y')}"
      end
    end

    # Closed periods take no more postings. Periods close in order (each after the ones
    # before it at its level) and closing a period closes the periods inside it, so a
    # closed period's balances can't be moved by later postings.
    def closed?
      closed_at.present?
    end

    # Why close! would be refused, or nil if the period can be closed.
    def close_blocker
      if closed? then "#{label} is already closed"
      elsif same_level.where("from_date < ?", from_date).where(closed_at: nil).exists? then "Close the earlier periods first"
      end
    end

    # Why reopen! would be refused (apart from a missing reason), or nil.
    def reopen_blocker
      if !closed? then "#{label} is not closed"
      elsif same_level.where("from_date > ?", from_date).where.not(closed_at: nil).exists? then "Reopen the later periods first"
      elsif parent&.closed? then "Reopen the year first"
      end
    end

    def close!(at: Time.current)
      blocker = close_blocker
      raise ArgumentError, blocker if blocker

      transaction do
        subtree.where(closed_at: nil).update_all(closed_at: at)
        reload
        AuditEvent.record!("period.closed", organization: organization, subject: self)
      end
    end

    # Reopening needs a reason, kept on the audit event.
    def reopen!(reason:)
      blocker = reopen_blocker || ("Give a reason for reopening #{label}" if reason.blank?)
      raise ArgumentError, blocker if blocker

      transaction do
        update!(closed_at: nil)
        AuditEvent.record!("period.reopened", organization: organization, subject: self, details: { reason: reason })
      end
    end

    def self.periods_for_date(org, date_or_time)
      moment = date_or_time.instance_of?(Date) ? date_or_time.in_time_zone(TudlaAccounting.configuration.time_zone) : date_or_time
      where(organization: org).includes_date?(moment)
    end

    def self.leaf_periods_for_date(org, date)
      periods_for_date(org, date).where(children_count: 0)
    end

    private

    def same_level
      self.class.where(organization: organization).at_depth(depth)
    end

    def check_period_length
      errors.add(:thru_date, "should be greater than from date") if from_date && thru_date && (from_date >= thru_date)
    end
  end
end
