# frozen_string_literal: true

module TudlaAccounting
  # A tax return's layout (a BAS, a VAT return): its boxes in order, each the sum of its
  # parts (see TaxReturnBox). TaxReturnCalculator works out a run of months' figures.
  #
  #   form = TaxReturnForm.from_template!(organization, "au_bas") # the boxes, without their tax codes
  #   form.boxes.find_by!(label: "1A").parts.create!(source: "tax_code_tax", tax_code: gst)
  class TaxReturnForm < ApplicationRecord
    belongs_to :organization, polymorphic: true
    has_many :boxes, -> { order(:position, :id) }, class_name: "TudlaAccounting::TaxReturnBox", foreign_key: :form_id, inverse_of: :form

    normalizes :name, with: ->(name) { name.strip }
    validates :name, presence: true, uniqueness: { scope: %i[organization_type organization_id] }

    after_create { audit("tax_return_form.created") }
    after_update { audit("tax_return_form.updated", changes: saved_changes.except("created_at", "updated_at")) if saved_changes.except("created_at", "updated_at").any? }
    after_destroy { audit("tax_return_form.deleted") }

    # A form laid out as a template (TaxReturnTemplates) says, its boxes' totals of other
    # boxes included; the tax codes and accounts are the organization's to add.
    def self.from_template!(organization, key, name: nil)
      template = TaxReturnTemplates.fetch(key)
      transaction do
        form = create!(organization: organization, name: name.presence || template[:name])
        template[:boxes].each_with_index do |spec, index|
          box = form.boxes.new(label: spec[:label], name: spec[:name], whole_units: spec.fetch(:whole_units, false), position: (index + 1) * 10)
          spec.fetch(:boxes, {}).each { |label, sign| box.parts.build(source: "box", sign: sign, from_box: form.boxes.find_by!(label: label)) }
          box.save!
        end
        form.boxes.reset
        form
      end
    end

    # Records a change to one of its boxes on the audit trail, as a change to the form.
    def box_changed(box, change)
      audit("tax_return_form.updated", box: box.label, change: change)
    end

    private

    def audit(action, **details)
      AuditEvent.record!(action, organization: organization, subject: self, details: details)
    end
  end
end
