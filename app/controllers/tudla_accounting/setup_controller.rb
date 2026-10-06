require "csv"

module TudlaAccounting
  # Getting an organization's books started: loading a chart of accounts with opening
  # balances, importing the receivables and payables open at the cut-over, and running
  # the period-end foreign exchange revaluation; and checking the stored balances against
  # the posted entries.
  class SetupController < ApplicationController
    permits :administer, only: %i[index opening_balances save_opening_balances chart_of_accounts open_items revaluation balances rebuild_balances]

    LOADERS = { ".csv" => CsvLoader, ".xlsx" => XlsxLoader }.freeze
    PROBLEMS = [ ArgumentError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, CSV::MalformedCSVError,
                 ForexRateRetriever::RateNotFound, Zip::Error ].freeze

    def index
      @first_year = organization_scope(Period).roots.order(:from_date).first
      @accounts = organization_scope(Account).order(:code)
      @months = organization_scope(Period).where.not(ancestry: "/").where(thru_date: ..Time.current.end_of_day).order(from_date: :desc)
      @config = TudlaAccounting.configuration
    end

    def opening_balances
      @form = OpeningBalancesForm.new(accounting_organization)
    end

    def save_opening_balances
      @form = OpeningBalancesForm.new(accounting_organization)
      if @form.save(params.fetch(:amounts, {}).permit!.to_h)
        redirect_to reports_balance_sheet_path(period_id: @form.year.children.order(:from_date).first.id),
                    notice: "Opening balances saved at #{helpers.tc_date(@form.year.from_date)}."
      else
        render :opening_balances, status: :unprocessable_entity
      end
    rescue ArgumentError => e
      redirect_to setup_path, alert: "The opening balances were not saved: #{e.message}"
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

    def balances
      @differences = BalanceRebuilder.new(accounting_organization).differences
        .sort_by { |difference| [ difference.period.from_date, -difference.period.thru_date.to_i, difference.account.code ] }
    end

    def rebuild_balances
      corrected = BalanceRebuilder.new(accounting_organization).rebuild!
      notice = corrected.zero? ? "The balances already agree with the posted entries." : "Corrected #{corrected} #{'balance'.pluralize(corrected)} from the posted entries."
      redirect_to setup_balances_path, notice: notice
    end
  end
end
