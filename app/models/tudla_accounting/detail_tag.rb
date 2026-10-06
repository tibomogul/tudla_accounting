# frozen_string_literal: true

module TudlaAccounting
  # An entry line tagged with a dimension value. A line has at most one value per dimension.
  class DetailTag < ApplicationRecord
    belongs_to :detail, class_name: "TudlaAccounting::Detail", inverse_of: :tags
    belongs_to :dimension, class_name: "TudlaAccounting::Dimension"
    belongs_to :dimension_value, class_name: "TudlaAccounting::DimensionValue"

    before_validation { self.dimension = dimension_value&.dimension }
    validate :same_organization

    private

    def same_organization
      return unless dimension && detail

      errors.add(:dimension_value, "must belong to the same organization") if dimension.organization_type != detail.organization_type || dimension.organization_id != detail.organization_id
    end
  end
end
