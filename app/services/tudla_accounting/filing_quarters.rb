# frozen_string_literal: true

module TudlaAccounting
  # The three-month quarters taxes are filed for, counted from the start of the financial
  # year a day falls in, or from January for a day no year covers.
  #
  #   FilingQuarters.new(organization).of(Date.new(2026, 5, 3)).label # => "Apr–Jun 2026"
  class FilingQuarters
    Quarter = Data.define(:from, :thru) do
      def label
        return "#{from.strftime('%b')}–#{thru.strftime('%b %Y')}" if from.year == thru.year

        "#{from.strftime('%b %Y')}–#{thru.strftime('%b %Y')}"
      end

      def range = from..thru
    end

    def initialize(organization)
      @starts = Period.where(organization: organization).roots.map { |year| year.from_date.to_date..year.thru_date.to_date }
    end

    def of(date)
      start = @starts.find { |year| year.cover?(date) }&.begin || date.beginning_of_year
      months = (date.year * 12 + date.month) - (start.year * 12 + start.month)
      from = start >> (months / 3 * 3)
      Quarter.new(from: from, thru: (from >> 3) - 1)
    end
  end
end
