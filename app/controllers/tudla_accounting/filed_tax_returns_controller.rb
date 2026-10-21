module TudlaAccounting
  # Tax returns as filed: filing one from the Tax return report, the list, each against
  # what the books now say, and withdrawing one. See FiledTaxReturn.
  class FiledTaxReturnsController < ApplicationController
    permits :administer, only: %i[create withdraw]

    before_action :set_filed, only: %i[show withdraw]

    def index
      @filed = organization_scope(FiledTaxReturn).includes(:form).newest_first.to_a
      @changed = @filed.reject(&:withdrawn?).to_h { |filed| [ filed.id, filed.changes.size ] }
    end

    def show
      @comparison = @filed.comparison
      months = organization_scope(Period).where(children_count: 0).where(from_date: @filed.from_date.., thru_date: ..@filed.thru_date)
      @open_months = months.where(closed_at: nil).order(:from_date).to_a
    end

    # Files the return of a form (form_id) for a run of months (from_id, thru_id) on a basis.
    def create
      form = organization_scope(TaxReturnForm).find(params.require(:form_id))
      from, thru = [ params.require(:from_id), params.require(:thru_id) ].map { |id| organization_scope(Period).find(id) }.minmax_by(&:from_date)
      filed = FiledTaxReturn.file!(form, from: from.from_date, thru: thru.thru_date, basis: params[:basis].presence_in(TaxReport::BASES.map(&:to_s)))
      redirect_to filed_tax_return_path(filed), notice: "#{filed.label} marked as filed."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to reports_tax_return_path(form_id: form.id, from_id: from.id, thru_id: thru.id, basis: params[:basis]),
                  alert: "It was not marked as filed: #{e.record.errors.full_messages.to_sentence}."
    end

    def withdraw
      @filed.withdraw!(reason: params[:reason])
      redirect_to filed_tax_return_path(@filed), notice: "#{@filed.label} withdrawn. A corrected return can now be filed for these months."
    rescue ArgumentError => e
      redirect_to filed_tax_return_path(@filed), alert: e.message
    end

    private

    def set_filed
      @filed = organization_scope(FiledTaxReturn).find(params[:id])
    end
  end
end
