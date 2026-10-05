module TudlaAccounting
  class DashboardController < ApplicationController
    def index
      @account_count = organization_scope(Account).count
      @year_count = organization_scope(Period).roots.count
      @draft_count = organization_scope(Entry).where(posted_at: nil).count
      @current_period = Period.leaf_periods_for_date(accounting_organization, Time.current).first
      # Income and expenses restart each year, so the current month's closing balances are the year to date.
      @profit_this_year = Reports::Statement.new(accounting_organization, @current_period).net_profit if @current_period
      @receivables = AgingReportGenerator.call(organization: accounting_organization, report_type: :receivable)[:totals]
      @payables = AgingReportGenerator.call(organization: accounting_organization, report_type: :payable)[:totals]
      @recent_entries = organization_scope(Entry).includes(:details).order(transacted_at: :desc, id: :desc).limit(8)
    end
  end
end
