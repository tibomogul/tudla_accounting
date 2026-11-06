module TudlaAccounting
  module Api
    module V1
      # The reports, as the pages' downloads lay them out: { "report", "data": { "headings",
      # "rows": [{ "cells", "total" }] } }, with the parameters the pages take:
      #
      #   balance_sheet, trial_balance        period_id (a month; this month by default)
      #   profit_and_loss                     period_id (a year or month; this year by default),
      #                                       compare (previous, last_year, months, budget, budget-<id>)
      #   balance_sheet                       compare too (previous, last_year, months)
      #   receivables, payables               as_of (a date; today by default)
      #   tax                                 from_id, thru_id (months), basis (accrual or cash)
      #   general_ledger                      from_id, thru_id, account (a code)
      #   cash_flow                           from_id, thru_id (the start of the year to this month by default),
      #                                       method (direct or indirect)
      #   withholding, qap, sawt              from_id, thru_id (this quarter by default)
      #   payee_payments, taxable_payments    from_id, thru_id (the last financial year by default)
      #   sales_list, purchases_list          from_id, thru_id (this quarter by default)
      class ReportsController < BaseController
        include ReportPeriods

        REPORTS = %w[balance_sheet profit_and_loss trial_balance receivables payables tax general_ledger cash_flow withholding qap sawt payee_payments taxable_payments sales_list purchases_list].freeze

        def show
          report = params[:report].presence_in(REPORTS) or raise ActiveRecord::RecordNotFound
          table = send(:"#{report}_table")
          return error(:no_periods, "The books have no periods for this report yet", :not_found) unless table

          render json: { report: report, data: table.as_api }
        end

        private

        def balance_sheet_table
          @period = chosen_period(months) or return
          @comparison = comparison(Reports::BalanceSheet)
          statement_table(Reports::BalanceSheet, sections: [ [ "asset" ], [ "liability" ], [ "equity", "Total equity before current-year earnings" ] ],
                                                 figures: [ [ :current_year_earnings, "Current-year earnings" ], [ :total_equity, "Total equity" ],
                                                            [ :liabilities_and_equity, "Total liabilities and equity" ] ])
        end

        def profit_and_loss_table
          @period = chosen_period(years + months, default: current_year) or return
          @budgets = organization_scope(Budget).where(period_id: @period.root_id).order(main: :desc, name: :asc).to_a
          @comparison = budget_comparison || (comparison(Reports::ProfitAndLoss) unless @compare)
          statement_table(Reports::ProfitAndLoss, sections: [ [ "income" ], [ "expense" ] ], figures: [ [ :net_profit, "Net profit (loss)" ] ])
        end

        def trial_balance_table
          period = chosen_period(months) or return
          Reports::Tables.trial_balance(Reports::TrialBalance.new(accounting_organization, period))
        end

        def receivables_table = aging_table(:receivable)
        def payables_table = aging_table(:payable)

        def aging_table(type)
          as_of = date_param(:as_of) || Date.current
          Reports::Tables.aging(AgingReportGenerator.call(organization: accounting_organization, report_type: type, as_of_date: as_of),
                                party_name: helpers.method(:related_party_name))
        end

        def tax_table
          month_range or return
          Reports::Tables.tax(TaxReport.call(accounting_organization, from: @from.from_date, thru: @thru.thru_date, basis: params[:basis].presence_in(TaxReport::BASES.map(&:to_s))))
        end

        def withholding_table = withholding_report&.then { |report| Reports::Tables.withholding_summary(report) }
        def qap_table = withholding_report&.then { |report| Reports::Tables.qap(report) }
        def sawt_table = withholding_report&.then { |report| Reports::Tables.sawt(report) }
        def taxable_payments_table = month_range(last_year: true) && Reports::Tables.taxable_payments(Reports::TaxablePayments.new(accounting_organization, from: @from, thru: @thru))
        def payee_payments_table = month_range(last_year: true) && Reports::Tables.payee_payments(Reports::PayeePayments.new(accounting_organization, from: @from, thru: @thru))

        def sales_list_table = summary_list_table(:sales)
        def purchases_list_table = summary_list_table(:purchases)

        def summary_list_table(side)
          month_range(quarter: true) && Reports::Tables.summary_list(Reports::SummaryLists.new(accounting_organization, from: @from, thru: @thru), side)
        end

        def withholding_report
          month_range(quarter: true) && Reports::Withholding.new(accounting_organization, from: @from, thru: @thru)
        end

        def general_ledger_table
          month_range or return
          account = organization_scope(Account).find_by!(code: params[:account]) if params[:account].present?
          Reports::GeneralLedger.new(accounting_organization, from: @from, thru: @thru, account_ids: account && [ account.id ]).to_table
        end

        def cash_flow_table
          month_range(year_to_date: true) or return
          report = Reports::CashFlow.new(accounting_organization, from: @from, thru: @thru,
                                         method: params[:method].presence_in(Reports::CashFlow::METHODS.map(&:to_s)) || :direct)
          raise ArgumentError, "The cash flow statement needs the cash_account_codes setting" unless report.configured?

          Reports::Tables.cash_flow(report)
        end
      end
    end
  end
end
