module TudlaAccounting
  class ReportsController < ApplicationController
    GENERAL_LEDGER_PAGE = 500 # lines
    def index
    end

    def balance_sheet
      @period = chosen_period(months)
      @report = Reports::BalanceSheet.new(accounting_organization, @period) if @period
    end

    def profit_and_loss
      @period = chosen_period(years + months, default: current_year)
      @report = Reports::ProfitAndLoss.new(accounting_organization, @period) if @period
    end

    def trial_balance
      @period = chosen_period(months)
      @report = Reports::TrialBalance.new(accounting_organization, @period) if @period
    end

    def receivables
      aging(:receivable)
    end

    def payables
      aging(:payable)
    end

    # Tax collected and paid over a run of months (the month containing today by default).
    def tax
      return unless month_range

      @report = TaxReport.call(accounting_organization, from: @from.from_date, thru: @thru.thru_date,
                               basis: params[:basis].presence_in(TaxReport::BASES.map(&:to_s)))
    end

    # Profit and loss with a column per value of a dimension, over a run of months (the
    # current year to date by default).
    def by_dimension
      @dimensions = organization_scope(Dimension).order(:code).to_a
      return if @dimensions.empty? || !month_range(year_to_date: true)

      @dimension = params[:dimension_id].present? ? (@dimensions.find { |d| d.id == params[:dimension_id].to_i } || raise(ActiveRecord::RecordNotFound)) : @dimensions.first
      @report = DimensionReport.call(accounting_organization, @dimension, from: @from.from_date, thru: @thru.thru_date)
    end

    # Every posted line, account by account, over a run of months (this month by default).
    def general_ledger
      @accounts = organization_scope(Account).order(:code).to_a
      return unless month_range

      @account = params[:account_id].present? ? organization_scope(Account).find(params[:account_id]) : nil
      @report = Reports::GeneralLedger.new(accounting_organization, from: @from, thru: @thru, account_ids: @account && [ @account.id ])
      respond_to do |format|
        format.html { @page = Paginator.new(@report.rows, page: params[:page], per_page: GENERAL_LEDGER_PAGE) }
        format.csv { send_data @report.to_csv, filename: "general-ledger-#{@from.from_date.to_date}-to-#{@thru.thru_date.to_date}.csv", type: "text/csv" }
      end
    end

    # Cash in and out by activity over a run of months (the year to date by default), for
    # the chosen cash accounts or those configured.
    def cash_flow
      @accounts = organization_scope(Account).where(category: [ Account::CATEGORY_ASSET, Account::CATEGORY_LIABILITY ]).order(:code).to_a
      return unless month_range(year_to_date: true)

      chosen = params[:cash_account_ids].present? ? organization_scope(Account).where(id: Array(params[:cash_account_ids])).to_a : nil
      @report = Reports::CashFlow.new(accounting_organization, from: @from, thru: @thru, cash_accounts: chosen)
    end

    private

    # @months, and the run @from..@thru picked with from_id/thru_id (either way round), by
    # default this month or (year_to_date) the start of its year to it. False without months.
    def month_range(year_to_date: false)
      @months = months.reverse
      return false if @months.empty?

      current = @months.find { |month| month.includes_date?(Time.current) }
      default_thru = current || @months.last
      default_from = year_to_date ? @months.find { |month| month.parent_id == default_thru.parent_id } : default_thru
      @from = picked_month(:from_id) || default_from
      @thru = picked_month(:thru_id) || (params[:from_id].present? && !year_to_date ? @from : default_thru)
      @from, @thru = @thru, @from if @thru.from_date < @from.from_date
      true
    end

    def picked_month(param)
      return if params[param].blank?

      @months.find { |month| month.id == params[param].to_i } || raise(ActiveRecord::RecordNotFound)
    end

    def years
      organization_scope(Period).roots.order(from_date: :desc).to_a
    end

    def months
      organization_scope(Period).where.not(ancestry: "/").order(from_date: :desc).to_a.select { |period| period.children_count.zero? }
    end

    def current_year
      Period.periods_for_date(accounting_organization, Time.current).roots.first
    end

    # The period picked (one of the choices), else the default: the one containing today,
    # else the most recent.
    def chosen_period(choices, default: nil)
      @choices = choices
      return choices.find { |period| period.id == params[:period_id].to_i } || raise(ActiveRecord::RecordNotFound) if params[:period_id].present?

      default || choices.find { |period| period.includes_date?(Time.current) } || choices.find { |period| period.from_date <= Time.current } || choices.last
    end

    def aging(type)
      @type = type
      @as_of = params[:as_of].presence&.to_date || Date.current
      @report = AgingReportGenerator.call(organization: accounting_organization, report_type: type, as_of_date: @as_of)
      render :aging
    end
  end
end
