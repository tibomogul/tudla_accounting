require "csv"

module TudlaAccounting
  # Getting an organization's books started: loading a chart of accounts with opening
  # balances, importing the receivables and payables open at the cut-over, and running
  # the period-end foreign exchange revaluation.
  class SetupController < ApplicationController
    LOADERS = { ".csv" => CsvLoader, ".xlsx" => XlsxLoader }.freeze
    PROBLEMS = [ ArgumentError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, CSV::MalformedCSVError,
                 ForexRateRetriever::RateNotFound, Zip::Error ].freeze

    def index
      @first_year = organization_scope(Period).roots.order(:from_date).first
      @accounts = organization_scope(Account).order(:code)
      @months = organization_scope(Period).where.not(ancestry: "/").where(thru_date: ..Time.current.end_of_day).order(from_date: :desc)
      @config = TudlaAccounting.configuration
    end

    def chart_of_accounts
      file = params.require(:file)
      loader = LOADERS[File.extname(file.original_filename).downcase]
      raise ArgumentError, "Upload a .csv or .xlsx file" unless loader

      before = organization_scope(Account).count
      loader.call(accounting_organization, file.path, Date.parse(params.require(:opening_date)), params[:overwrite] == "1")
      redirect_to accounts_path, notice: "Chart of accounts loaded: #{organization_scope(Account).count - before} new accounts, with opening balances."
    rescue *PROBLEMS, Date::Error, ActionController::ParameterMissing => e
      redirect_to setup_path, alert: "The chart of accounts was not loaded: #{e.message}"
    end

    def open_items
      amounts = CarryingAmountsCreator.call(
        organization: accounting_organization, csv_file: params.require(:file).path, date_prior: Date.parse(params.require(:date_prior)),
        sales_account_code: params[:sales_account_code], purchase_account_code: params[:purchase_account_code]
      )
      redirect_to reports_receivables_path, notice: "Imported #{amounts.size} open #{'item'.pluralize(amounts.size)}."
    rescue *PROBLEMS, Date::Error, ActionController::ParameterMissing => e
      redirect_to setup_path, alert: "The open items were not imported: #{e.message}"
    end

    def revaluation
      month = organization_scope(Period).find(params.require(:period_id))
      period_end = month.thru_date.in_time_zone(TudlaAccounting.configuration.time_zone).to_date
      entries = RevaluationEntryGenerator.call(accounting_organization, period_end, period_end + 1)
      notice = entries.empty? ? "Nothing to revalue at #{helpers.tc_date(period_end)}." : "Posted #{entries.size} revaluation entries for #{helpers.tc_date(period_end)}."
      redirect_to entries_path(q: "Revaluation"), notice: notice
    rescue *PROBLEMS, ActionController::ParameterMissing => e
      redirect_to setup_path, alert: "The revaluation was not run: #{e.message}"
    end
  end
end
