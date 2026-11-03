# frozen_string_literal: true

module TudlaAccounting
  # A rate kept as a fraction (0.1) and read and written as a percentage in the
  # organization's number format: tax codes' and withholding codes'.
  module PercentRate
    extend ActiveSupport::Concern

    included do
      validate { errors.add(:rate, "#{@unreadable_rate} isn't a number") if @unreadable_rate }
    end

    # "10" for 0.1, "12.5" (or "12,5") for 0.125.
    def rate_percent
      rate && AmountParser.number_text(rate * 100, format: number_format)
    end

    def rate_percent=(percent)
      self.rate = AmountParser.decimal(percent, format: number_format)&./(100)
    rescue ArgumentError
      self.rate = nil
      @unreadable_rate = percent
    end

    def number_format = organization ? NumberFormat.for(organization) : AmountParser::POINT

    # "GST (10%)"
    def label
      "#{code} (#{rate_percent}%)"
    end
  end
end
