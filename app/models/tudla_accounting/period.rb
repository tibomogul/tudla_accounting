# frozen_string_literal: true

module TudlaAccounting
  class Period < ApplicationRecord
    include DatetimeRange
    has_ancestry orphan_strategy: :restrict, cache_depth: true, counter_cache: true, ancestry_format: :materialized_path2
    belongs_to :organization, polymorphic: true

    validates :from_date, :thru_date, presence: true
    validate :check_period_length

    has_many :balances, dependent: :destroy, class_name: "TudlaAccounting::Balance"

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
    def self.periods_for_date(org, date_or_time)
      moment = date_or_time.instance_of?(Date) ? date_or_time.in_time_zone(TudlaAccounting.configuration.time_zone) : date_or_time
      where(organization: org).includes_date?(moment)
    end

    def self.leaf_periods_for_date(org, date)
      periods_for_date(org, date).where(children_count: 0)
    end

    private

    def check_period_length
      errors.add(:thru_date, "should be greater than from date") if from_date && thru_date && (from_date >= thru_date)
    end
  end
end
