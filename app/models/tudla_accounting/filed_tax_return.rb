# frozen_string_literal: true

module TudlaAccounting
  # A tax return as it was filed: a form's figures (TaxReturnCalculator's) for a run of
  # months on a basis, who filed it and when. Its figures never change; changes shows
  # where the books now say otherwise (something posted into the months since, or the
  # form's boxes changed). Filed returns of a form can't overlap, unless one was
  # withdrawn (withdraw!, with a reason), so a corrected return can be filed.
  #
  #   filed = FiledTaxReturn.file!(bas, from: july.from_date, thru: september.thru_date, basis: :cash)
  #   filed.changes # => [{ label: "1A", name: "GST on sales", filed: $1,000, now: $1,100 }]
  #   filed.withdraw!(reason: "Missed an invoice")
  class FiledTaxReturn < ApplicationRecord
    belongs_to :organization, polymorphic: true
    belongs_to :form, class_name: "TudlaAccounting::TaxReturnForm"

    validates :basis, inclusion: { in: TaxReport::BASES.map(&:to_s) }
    validate :dates_in_order
    validate :no_overlap, on: :create

    scope :active, -> { where(withdrawn_at: nil) }
    scope :newest_first, -> { order(from_date: :desc, id: :desc) }

    # Files the form's return for the span, as the books are now.
    def self.file!(form, from:, thru:, basis: nil)
      transaction do
        form.lock! # one filing of a form at a time, so two can't overlap
        report = TaxReturnCalculator.call(form, from: from, thru: thru, basis: basis)
        filed = create!(organization: form.organization, form: form, from_date: from, thru_date: thru, basis: report[:basis].to_s,
                        figures: report[:boxes].map { |row| { "label" => row.box.label, "name" => row.box.name, "cents" => row.amount.cents } },
                        filed_at: Time.current, filed_by: AuditEvent.label_for(Current.actor))
        AuditEvent.record!("tax_return.filed", organization: filed.organization, subject: filed, details: { figures: filed.figures.to_h { |box| [ box["label"], box["cents"] ] } })
        filed
      end
    end

    def withdrawn?
      withdrawn_at.present?
    end

    # Takes it back, so a corrected return can be filed for the months.
    def withdraw!(reason:)
      raise ArgumentError, "This return has already been withdrawn" if withdrawn?
      raise ArgumentError, "Say why it is withdrawn" if reason.to_s.strip.empty?

      transaction do
        update!(withdrawn_at: Time.current, withdrawn_by: AuditEvent.label_for(Current.actor), withdrawn_reason: reason.strip)
        AuditEvent.record!("tax_return.withdrawn", organization: organization, subject: self, details: { reason: withdrawn_reason })
      end
    end

    # "BAS, 1 Jul 2026 to 30 Sep 2026".
    def label
      "#{form.name}, #{from_date.to_date.strftime('%-d %b %Y')} to #{thru_date.to_date.strftime('%-d %b %Y')}"
    end

    # Each box as filed and as the books now give it ({ label:, name:, filed:, now: }), the
    # boxes added since with nothing filed, and those removed with nothing now.
    def comparison
      now = TaxReturnCalculator.call(form, from: from_date, thru: thru_date, basis: basis)[:boxes].to_h { |row| [ row.box.label, row ] }
      filed = figures.to_h { |box| [ box["label"], box ] }
      (filed.keys | now.keys).map do |label|
        { label: label, name: now[label]&.box&.name || filed[label]["name"], filed: filed[label] && money(filed[label]["cents"]), now: now[label]&.amount }
      end
    end

    # The boxes whose figure is not what was filed.
    def changes
      comparison.reject { |box| box[:filed] == box[:now] }
    end

    private

    def dates_in_order
      errors.add(:thru_date, "must be after the start") if from_date && thru_date && thru_date < from_date
    end

    def no_overlap
      return unless form && from_date && thru_date

      overlap = FiledTaxReturn.active.where(form: form).where("from_date <= ? AND thru_date >= ?", thru_date, from_date).first
      errors.add(:base, "#{overlap.label} was filed already; withdraw it first to file these months again") if overlap
    end

    def money(cents)
      Money.new(cents, organization.currency)
    end
  end
end
