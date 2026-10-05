module TudlaAccounting
  class DashboardController < ApplicationController
    def index
      @account_count = organization_scope(Account).count
      @year_count = organization_scope(Period).roots.count
      @draft_count = organization_scope(Entry).where(posted_at: nil).count
      @current_period = Period.leaf_periods_for_date(accounting_organization, Time.current).first
    end
  end
end
