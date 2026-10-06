# frozen_string_literal: true

module TudlaAccounting
  # A way of analysing the books beyond accounts (department, project, location...): its
  # values tag entry lines, at most one value of each dimension per line, and reports can
  # be broken down by them.
  class Dimension < ApplicationRecord
    belongs_to :organization, polymorphic: true
    has_many :dimension_values, -> { order(:code) }, class_name: "TudlaAccounting::DimensionValue", dependent: :restrict_with_error,
                                                     inverse_of: :dimension
    has_many :tags, class_name: "TudlaAccounting::DetailTag", dependent: :restrict_with_error

    validates :code, :name, presence: true
    validates :code, uniqueness: { scope: %i[organization_type organization_id] }

    after_create { audit("dimension.created") }
    after_update { audit("dimension.updated", changes: saved_changes.except("created_at", "updated_at")) if saved_changes.except("created_at", "updated_at").any? }

    scope :active, -> { where(active: true) }

    def label
      "#{name} (#{code})"
    end

    def used?
      tags.exists?
    end

    private

    def audit(action, **details)
      AuditEvent.record!(action, organization: organization, subject: self, details: details)
    end
  end
end
