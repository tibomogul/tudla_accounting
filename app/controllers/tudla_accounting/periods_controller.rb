module TudlaAccounting
  class PeriodsController < ApplicationController
    def index
      @years = organization_scope(Period).roots.order(from_date: :desc).to_a
    end

    def show
      @year = organization_scope(Period).roots.find(params[:id])
      @months = @year.children.order(:from_date).to_a
      @line_counts = Detail.joins(:balance).where(tudla_accounting_balances: { period_id: @months.map(&:id) })
        .group("tudla_accounting_balances.period_id").count
    end

    def new
      @form = year_form(year: Date.current.year, start_month: 1, start_day: 1)
    end

    def create
      @form = year_form(**params.require(:year).permit(:year, :start_month, :start_day).to_h.symbolize_keys.transform_values(&:to_i))
      year = PeriodCreator.call(accounting_organization, @form.year, @form.start_month, @form.start_day)
      raise PeriodInvalid, "The year could not be created" unless year

      redirect_to period_path(year), notice: "Financial year #{year_label(year)} was created."
    rescue PeriodInvalid => e
      @error = e.message
      render :new, status: :unprocessable_entity
    end

    def destroy
      year = organization_scope(Period).roots.find(params[:id])
      if year.deletable?
        year.destroy_with_subtree!
        redirect_to periods_path, notice: "Financial year #{year_label(year)} was deleted."
      else
        redirect_to period_path(year), alert: "A year with postings can't be deleted."
      end
    end

    # Closes a year or one of its months (both identified by id under the year's page).
    def close
      period = organization_scope(Period).find(params[:id])
      period.close!
      redirect_to period_path(period.root), notice: "#{year_label(period)} is closed: nothing more can be posted to it."
    rescue ArgumentError => e
      redirect_to period_path(period.root), alert: "#{year_label(period)} was not closed: #{e.message.downcase_first}."
    end

    def reopen
      period = organization_scope(Period).find(params[:id])
      period.reopen!(reason: params[:reason])
      redirect_to period_path(period.root), notice: "#{year_label(period)} is open again."
    rescue ArgumentError => e
      redirect_to period_path(period.root), alert: "#{year_label(period)} was not reopened: #{e.message.downcase_first}."
    end

    private

    YearForm = Struct.new(:year, :start_month, :start_day, keyword_init: true)

    def year_form(**values)
      YearForm.new(**values)
    end

    def year_label(year)
      helpers.tc_period_label(year)
    end
  end
end
