module TudlaAccounting
  class ReportsController < ApplicationController
    GENERAL_LEDGER_PAGE = 500 # lines
    def index
    end

    # What a statement can be compared with: the period before, the same period a year
    # earlier, or each month of the year (up to the period chosen).
    COMPARISONS = { "previous" => "Previous period", "last_year" => "Same period last year", "months" => "Each month of the year" }.freeze

    def balance_sheet
      @period = chosen_period(months)
      @report = Reports::BalanceSheet.new(accounting_organization, @period) if @period
      @comparison = comparison(Reports::BalanceSheet) if @period
      respond_with_table("balance-sheet-#{@period&.thru_date&.to_date}") do
        statement_table(Reports::BalanceSheet, sections: [ [ "asset" ], [ "liability" ], [ "equity", "Total equity before current-year earnings" ] ],
                        figures: [ [ :current_year_earnings, "Current-year earnings" ], [ :total_equity, "Total equity" ],
                                   [ :liabilities_and_equity, "Total liabilities and equity" ] ])
      end
    end

    def profit_and_loss
      @period = chosen_period(years + months, default: current_year)
      @report = Reports::ProfitAndLoss.new(accounting_organization, @period) if @period
      @budgets = @period ? organization_scope(Budget).where(period_id: @period.root_id).order(main: :desc, name: :asc).to_a : []
      @comparison = (budget_comparison || (comparison(Reports::ProfitAndLoss) unless @compare)) if @period
      name = "profit-and-loss-#{@period&.from_date&.to_date}-to-#{@period&.thru_date&.to_date}#{"-vs-budget-#{@budget.name.parameterize}" if @budget && @comparison}"
      respond_with_table(name) do
        statement_table(Reports::ProfitAndLoss, sections: [ [ "income" ], [ "expense" ] ], figures: [ [ :net_profit, "Net profit (loss)" ] ])
      end
    end

    def trial_balance
      @period = chosen_period(months)
      @report = Reports::TrialBalance.new(accounting_organization, @period) if @period
      respond_with_table("trial-balance-#{@period&.thru_date&.to_date}") { Reports::Tables.trial_balance(@report) }
    end

    def receivables
      aging(:receivable)
    end

    def payables
      aging(:payable)
    end

    # Tax collected and paid over a run of months (the month containing today by default).
    def tax
      return respond_with_table("tax-summary") unless month_range

      @report = TaxReport.call(accounting_organization, from: @from.from_date, thru: @thru.thru_date,
                               basis: params[:basis].presence_in(TaxReport::BASES.map(&:to_s)))
      respond_with_table("tax-summary-#{@report[:basis]}-#{span_name}") { Reports::Tables.tax(@report) }
    end

    # Profit and loss with a column per value of a dimension, over a run of months (the
    # current year to date by default).
    def by_dimension
      @dimensions = organization_scope(Dimension).order(:code).to_a
      return respond_with_table("profit-and-loss-by-dimension") if @dimensions.empty? || !month_range(year_to_date: true)

      @dimension = params[:dimension_id].present? ? (@dimensions.find { |d| d.id == params[:dimension_id].to_i } || raise(ActiveRecord::RecordNotFound)) : @dimensions.first
      @report = DimensionReport.call(accounting_organization, @dimension, from: @from.from_date, thru: @thru.thru_date)
      respond_with_table("profit-and-loss-by-#{@dimension.code.parameterize}-#{span_name}") { Reports::Tables.by_dimension(@report) }
    end

    # Every posted line, account by account, over a run of months (this month by default).
    def general_ledger
      @accounts = organization_scope(Account).order(:code).to_a
      return respond_with_table("general-ledger") unless month_range

      @account = params[:account_id].present? ? organization_scope(Account).find(params[:account_id]) : nil
      @report = Reports::GeneralLedger.new(accounting_organization, from: @from, thru: @thru, account_ids: @account && [ @account.id ])
      respond_with_table("general-ledger-#{span_name}", html: -> { @page = Paginator.new(@report.rows, page: params[:page], per_page: GENERAL_LEDGER_PAGE) }) do
        @report.to_table
      end
    end

    # Cash in and out by activity over a run of months (the year to date by default), for
    # the chosen cash accounts or those configured.
    def cash_flow
      @accounts = organization_scope(Account).where(category: [ Account::CATEGORY_ASSET, Account::CATEGORY_LIABILITY ]).order(:code).to_a
      return respond_with_table("cash-flow") unless month_range(year_to_date: true)

      chosen = params[:cash_account_ids].present? ? organization_scope(Account).where(id: Array(params[:cash_account_ids])).to_a : nil
      @report = Reports::CashFlow.new(accounting_organization, from: @from, thru: @thru, cash_accounts: chosen,
                                      method: params[:method].presence_in(Reports::CashFlow::METHODS.map(&:to_s)) || :direct)
      respond_with_table("cash-flow-#{@report.flow_method}-#{span_name}", available: @report.configured?) { Reports::Tables.cash_flow(@report) }
    end

    # A customer's or supplier's statement of account (type, party) over a run of days
    # (from, thru; last month by default): their activity, or (show=open_items) what was
    # still open at the end. See PartyStatement. Without a party (or one of the other
    # type), the page asks for one.
    def statement
      statement_options
      party = @parties.find { |each| PartyStatement.key(each) == params[:party] } # none when the type changed
      if party
        @statement = PartyStatement.call(organization: accounting_organization, type: @type, party: party, from: @from, thru: @thru)
      end
      name = "statement-#{PartyStatement.party_name(party).parameterize if party}-#{@open_items ? "open-items-#{@thru}" : "#{@from}-to-#{@thru}"}"
      respond_with_table(name, available: !@statement.nil?) { Reports::Tables.party_statement(@statement, open_items: @open_items) }
    end

    # Every customer's (or supplier's) statement with something to send, one to a printed
    # page: those with a balance at either end or activity in between, or (open_items) with
    # anything open at the end.
    def statements
      statement_options
      @statements = @parties.map { |party| PartyStatement.call(organization: accounting_organization, type: @type, party: party, from: @from, thru: @thru) }
                            .reject { |statement| @open_items ? statement.open_items.empty? : statement.empty? }
      name = "statements-#{PartyStatement::PARTY_NAMES.fetch(@type).downcase.pluralize}-#{@open_items ? "open-items-#{@thru}" : "#{@from}-to-#{@thru}"}"
      respond_with_table(name, available: true) { Reports::Tables.party_statements(@statements, type: @type, open_items: @open_items) }
    end

    private

    # What the statement pages share: the type, its parties, the dates and what to show.
    def statement_options
      @type = params[:type].presence_in(%w[receivable payable])&.to_sym || :receivable
      @parties = PartyStatement.parties(accounting_organization, @type)
      @from, @thru = statement_dates
      @open_items = params[:show] == "open_items"
    end

    # The statement's first and last days, either way round; last month by default, and
    # for a date that can't be read.
    def statement_dates
      last_month = Date.current.prev_month
      dates = %i[from thru].map { |param| params[param].presence&.to_date }
      from = dates[0] || last_month.beginning_of_month
      thru = dates[1] || last_month.end_of_month
      [ from, thru ].minmax
    rescue Date::Error
      [ last_month.beginning_of_month, last_month.end_of_month ]
    end

    # The page (html, when given, prepares it), or the table the block gives as CSV, or as
    # an Excel workbook when the host has caxlsx. Not found when there is nothing to export
    # (no periods yet, say) or no Excel. The workbook's sheet is named after the file.
    def respond_with_table(name, available: !@report.nil?, html: nil, &table)
      respond_to do |format|
        format.html { html&.call }
        format.csv { available ? send_data(table.call.to_csv, filename: "#{name}.csv", type: "text/csv") : head(:not_found) }
        format.xlsx do
          next head(:not_found) unless available && TudlaAccounting.xlsx?

          send_data table.call.to_xlsx(name.titleize), filename: "#{name}.xlsx", type: Mime[:xlsx].to_s
        end
      end
    end

    # The statement on the page as a table: its comparison, or the period alone.
    def statement_table(report_class, sections:, figures:)
      comparison = @comparison || Reports::Comparison.new(report_class, accounting_organization, [ @period ])
      if comparison.is_a?(Reports::BudgetComparison)
        groups = helpers.budget_column_groups(comparison)
        return Reports::Tables.statement(comparison, labels: groups.flat_map { |group| [ "#{group} actual", "#{group} budget" ] }, sections: sections, figures: figures,
                                                     change: true, change_headings: groups.map { |group| [ "#{group} variance", "#{group} variance %" ] })
      end
      Reports::Tables.statement(comparison, labels: comparison.periods.map { |period| helpers.comparison_label(period, @compare) },
                                            sections: sections, figures: figures, change: comparison.periods.size == 2 && @compare != "months")
    end

    # "2026-03-01-to-2026-05-31" for the months picked.
    def span_name
      "#{@from.from_date.to_date}-to-#{@thru.thru_date.to_date}"
    end

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

    # The statement for @period beside the periods the compare parameter asks for, or nil
    # when it asks for none or there is nothing to compare with (@compare says what was
    # asked for, so the page can say so).
    def comparison(report_class)
      @compare = params[:compare].presence_in(COMPARISONS.keys)
      return unless @compare

      periods = compared_periods(@period)
      periods.size > 1 ? Reports::Comparison.new(report_class, accounting_organization, periods) : nil
    end

    # Budget vs actual for @period, when the compare parameter asks for a budget: "budget"
    # for the year's main budget (or its first), "budget-<id>" for another of its budgets.
    # Nil, with @compare set, when the year has none.
    def budget_comparison
      match = params[:compare].to_s.match(/\Abudget(?:-(\d+))?\z/)
      return unless match

      @compare = "budget"
      @budget = @budgets.find { |budget| budget.id == match[1].to_i } || @budgets.first
      @budget && Reports::BudgetComparison.new(@budget, @period)
    end

    # The columns, the chosen period's among them. Beside the previous period or the same
    # one a year earlier (of the same kind: months beside a month, years beside a year),
    # the chosen period comes first. For each month, the months of its year in order, up
    # to the chosen month, or all of them and then the year as a whole when a year was
    # chosen (its total).
    def compared_periods(period)
      peers = organization_scope(Period).at_depth(period.depth).to_a
      case @compare
      when "previous" then [ period, peers.select { |peer| peer.thru_date < period.from_date }.max_by(&:from_date) ].compact
      when "last_year" then [ period, peers.find { |peer| peer.from_date.to_date == period.from_date.to_date.prev_year } ].compact
      when "months"
        year = period.root
        in_year = year.children.order(:from_date).to_a
        period.root? ? [ *in_year, year ] : in_year.select { |month| month.from_date <= period.from_date }
      end
    end

    def aging(type)
      @type = type
      @as_of = params[:as_of].presence&.to_date || Date.current
      @report = AgingReportGenerator.call(organization: accounting_organization, report_type: type, as_of_date: @as_of)
      respond_with_table("#{type}s-aging-#{@as_of}", html: -> { render :aging }) do
        Reports::Tables.aging(@report, party_name: helpers.method(:related_party_name))
      end
    end
  end
end
