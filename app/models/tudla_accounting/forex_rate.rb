# frozen_string_literal: true

module TudlaAccounting
  class ForexRate < ApplicationRecord
    validates :from, presence: true
    validates :to, presence: true
    validates :rate, presence: true, numericality: true
    validates :year, presence: true, numericality: { only_integer: true }
    validates :month, presence: true, numericality: { only_integer: true }
    validates :day, presence: true, numericality: { only_integer: true }
  end
end
