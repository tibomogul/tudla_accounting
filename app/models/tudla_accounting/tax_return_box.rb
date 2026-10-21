# frozen_string_literal: true

module TudlaAccounting
  # A box of a tax return form: label ("G1", "Box 6"), name, its place on the form, and
  # the parts it adds up (TaxReturnBoxPart). whole_units drops the cents, as some forms
  # ask. A box can use only boxes above it, so the form works out top to bottom.
  class TaxReturnBox < ApplicationRecord
    belongs_to :form, class_name: "TudlaAccounting::TaxReturnForm", inverse_of: :boxes
    has_many :parts, -> { order(:id) }, class_name: "TudlaAccounting::TaxReturnBoxPart", foreign_key: :box_id, inverse_of: :box, dependent: :delete_all
    has_many :uses, class_name: "TudlaAccounting::TaxReturnBoxPart", foreign_key: :from_box_id, inverse_of: :from_box

    accepts_nested_attributes_for :parts, allow_destroy: true, reject_if: ->(attributes) { attributes["id"].blank? && attributes["source"].blank? }

    normalizes :label, :name, with: ->(text) { text.strip }
    validates :label, :name, presence: true
    validates :label, uniqueness: { scope: :form_id }
    validates :position, numericality: { only_integer: true }
    validate :parts_fit
    validate :users_stay_below, if: -> { persisted? && will_save_change_to_position? }

    before_destroy :ensure_unused
    after_create { form.box_changed(self, "added") }
    after_update { form.box_changed(self, "changed") }
    after_destroy { form.box_changed(self, "removed") }

    # "G1 Total sales".
    def title
      "#{label} #{name}"
    end

    private

    def parts_fit
      organization = form&.organization
      parts.reject(&:marked_for_destruction?).each do |part|
        if part.tax_code && part.tax_code.organization != organization then errors.add(:base, "#{part.tax_code.code} isn't one of the organization's tax codes")
        elsif part.account && part.account.organization != organization then errors.add(:base, "#{part.account.code} isn't one of the organization's accounts")
        elsif part.from_box && (part.from_box.form_id != form_id || part.from_box.position >= position.to_i || part.from_box == self)
          errors.add(:base, "#{part.from_box.label} must be a box above this one on the form")
        end
      end
    end

    def users_stay_below
      user = uses.includes(:box).map(&:box).find { |box| box.position <= position }
      errors.add(:position, "must stay above #{user.label}, which uses this box") if user
    end

    def ensure_unused
      user = uses.includes(:box).first&.box
      return unless user

      errors.add(:base, "#{user.label} uses #{label}; change it first")
      throw :abort
    end
  end
end
