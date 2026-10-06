# frozen_string_literal: true

module TudlaAccounting
  # One value of a dimension, e.g. "Sales" of Department.
  class DimensionValue < ApplicationRecord
    belongs_to :dimension, class_name: "TudlaAccounting::Dimension", inverse_of: :dimension_values
    has_many :tags, class_name: "TudlaAccounting::DetailTag", dependent: :restrict_with_error

    validates :code, :name, presence: true
    validates :code, uniqueness: { scope: :dimension_id }

    after_create { audit("dimension_value.created") }
    after_update { audit("dimension_value.updated", changes: saved_changes.except("created_at", "updated_at")) if saved_changes.except("created_at", "updated_at").any? }

    scope :active, -> { where(active: true) }

    # "Department: Sales"
    def label
      "#{dimension.name}: #{name}"
    end

    def used?
      tags.exists?
    end

    private

    def audit(action, **details)
      AuditEvent.record!(action, organization: dimension.organization, subject: self, details: details)
    end
  end
end
