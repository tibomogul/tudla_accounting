# frozen_string_literal: true

module TudlaAccounting
  # Creates a financial year for an organization: a root period spanning the year
  # and twelve monthly child periods. Periods run from the start of their first day
  # to the end of their last day (in the configured time zone), which is what
  # DatetimeRange#abuts? and Period#partitioned_by_children? expect.
  class PeriodCreator
    attr_reader :organization, :year, :start_month, :start_day

    def self.call(...)
      new(...).call
    end

    def initialize(organization, year, start_month = 1, start_day = 1)
      raise TudlaAccounting::PeriodInvalid, "Year must be greater than 0" if year < 1
      raise TudlaAccounting::PeriodInvalid, "Start month must be between 1 and 12" if start_month < 1 || start_month > 12
      raise TudlaAccounting::PeriodInvalid, "Start day must be between 1 and 28" if start_day < 1 || start_day > 28

      @organization = organization
      @year = year
      @start_month = start_month
      @start_day = start_day
    end

    # Returns the root period, or nil (and logs) if any period fails validation.
    def call
      from_date = ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone].local(year, start_month, start_day)
      thru_date = (from_date.next_year - 1.day).end_of_day
      overlapping = TudlaAccounting::Period.roots.where(organization: organization).where("from_date <= ? AND thru_date >= ?", thru_date, from_date).exists?
      raise TudlaAccounting::PeriodInvalid, "The year overlaps an existing financial year" if overlapping

      TudlaAccounting::Period.transaction do
        root = TudlaAccounting::Period.create!(
          organization: organization,
          from_date: from_date.beginning_of_day,
          thru_date: thru_date
        )
        12.times do |month|
          month_start = from_date.advance(months: month)
          TudlaAccounting::Period.create!(
            organization: organization,
            parent: root,
            from_date: month_start.beginning_of_day,
            thru_date: (month_start.next_month - 1.day).end_of_day
          )
        end
        root
      end
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error(e.message)
      nil
    end
  end
end
