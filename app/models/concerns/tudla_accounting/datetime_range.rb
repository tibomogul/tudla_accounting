# frozen_string_literal: true

module TudlaAccounting
  module DatetimeRange
    include Comparable

    def self.included(klass)
      klass.extend ClassMethods
    end

    module ClassMethods
      def combination(collection_of_these)
        return nil if collection_of_these.empty?

        arr = collection_of_these.sort
        return nil unless is_contiguous?(arr)

        new(from_date: arr[0].from_date, thru_date: arr[arr.length - 1].thru_date)
      end

      def is_contiguous?(collection_of_these)
        return nil if collection_of_these.empty?
        return true if collection_of_these.length == 1

        arr = collection_of_these.sort
        0.upto(arr.length - 2) do |i|
          return false unless arr[i].abuts?(arr[i + 1])
        end
        true
      end

      def includes_date?(date)
        where(from_date: ..date).where(thru_date: date..)
      end
    end

    def <=>(other)
      return (from_date <=> other.from_date) unless from_date == other.from_date

      (thru_date <=> other.thru_date)
    end

    def includes_date?(date)
      from_date <= date && thru_date >= date
    end

    def includes_dates?(start_date, end_date)
      from_date <= start_date && thru_date >= end_date
    end

    def includes_other?(other)
      includes_date?(other.from_date) && includes_date?(other.thru_date)
    end

    def equals?(other)
      (from_date == other.from_date) && (thru_date == other.thru_date)
    end

    def overlaps?(other)
      other.includes_date?(from_date) || other.includes_date?(thru_date) || includes_other?(other)
    end

    def overlaps_dates?(start_date, end_date)
      (start_date..end_date).cover?(from_date) || (start_date..end_date).cover?(thru_date) || includes_dates?(
        start_date, end_date
      )
    end

    def gap(other)
      return nil if overlaps?(other)

      if (self <=> other).negative?
        lower = self
        higher = other
      else
        lower = other
        higher = self
      end
      return nil if (lower.thru_date + 1) > (higher.from_date - 1)

      ((lower.thru_date + 1)..(higher.from_date - 1))
    end

    def abuts?(other)
      !overlaps?(other) && gap(other).nil?
    end

    def partitioned_by?(collection_of_these)
      return false if collection_of_these.length < 2
      return false unless self.class.is_contiguous?(collection_of_these)

      equals?(self.class.combination(collection_of_these))
    end
  end
end
