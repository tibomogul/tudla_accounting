module TudlaAccounting
  # Budgets: their amounts, account by account and month by month, typed in or uploaded
  # as a spreadsheet, and downloaded. See Budget.
  class BudgetsController < ApplicationController
    permits :record, only: %i[new create edit update destroy upload]

    STARTS = { "blank" => "Blank", "actuals" => "A year's actual results", "budget" => "A copy of another budget" }.freeze

    before_action :set_budget, only: %i[show edit update destroy upload]

    def index
      @budgets = organization_scope(Budget).newest_first.includes(:period).to_a
      @grids = @budgets.to_h { |budget| [ budget.id, BudgetGrid.new(budget) ] }
    end

    def show
      @grid = BudgetGrid.new(@budget)
      name = "budget-#{@budget.period.label.parameterize}-#{@budget.name.parameterize}"
      respond_to do |format|
        format.html
        format.csv { send_data @grid.to_table.to_csv, filename: "#{name}.csv", type: "text/csv" }
        format.xlsx do
          next head(:not_found) unless TudlaAccounting.xlsx?

          send_data @grid.to_table.to_xlsx(name.titleize), filename: "#{name}.xlsx", type: Mime[:xlsx].to_s
        end
      end
    end

    def new
      year = years.find { |each| each.includes_date?(Time.current.next_year) } || years.first
      @budget = organization_scope(Budget).new(period: year, name: "Budget", main: year && organization_scope(Budget).where(period: year).none?)
      @start = "blank"
    end

    # The budget, filled as the start chosen says: blank, from a year's actual results
    # (changed by a percentage) or from another budget.
    def create
      @budget = organization_scope(Budget).new(params.require(:budget).permit(:name, :main).merge(period: years.find { |year| year.id == params[:budget][:period_id].to_i }))
      @start = params[:start].presence_in(STARTS.keys) || "blank"
      Budget.transaction do
        raise ActiveRecord::Rollback unless @budget.save

        fill_budget
      rescue ArgumentError => e
        @budget.errors.add(:base, e.message)
        raise ActiveRecord::Rollback
      end
      if @budget.persisted?
        redirect_to edit_budget_path(@budget), notice: "Budget #{@budget.label} added. Enter its amounts."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      @grid = BudgetGrid.new(@budget)
    end

    # The budget's name, whether it is the year's main budget, and its amounts.
    def update
      typed, problems = typed_amounts
      @budget.assign_attributes(params.require(:budget).permit(:name, :main))
      saved = problems.empty? && Budget.transaction do
        @budget.save && (@budget.set_amounts!(typed) || true)
      rescue ArgumentError => e
        problems << e.message
        raise ActiveRecord::Rollback
      end
      if saved
        redirect_to budget_path(@budget), notice: "Budget #{@budget.label} saved."
      else
        problems.each { |problem| @budget.errors.add(:base, problem) }
        @grid = BudgetGrid.new(@budget, amounts: typed)
        @typed = params.fetch(:amounts, {}).to_unsafe_h
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @budget.destroy!
      redirect_to budgets_path, notice: "Budget #{@budget.label} deleted."
    end

    # The amounts in a spreadsheet, for the accounts it has rows for.
    def upload
      file = params.require(:file)
      grid = BudgetGrid.new(@budget)
      amounts = grid.read(file.path, File.extname(file.original_filename).downcase)
      @budget.set_amounts!(amounts)
      redirect_to budget_path(@budget), notice: "Amounts for #{helpers.pluralize(amounts.size, 'account')} read from #{file.original_filename}."
    rescue ArgumentError, ActionController::ParameterMissing => e
      redirect_to budget_path(@budget), alert: "The file was not read: #{e.message.downcase_first}."
    end

    private

    def set_budget
      @budget = organization_scope(Budget).find(params[:id])
    end

    def years
      @years ||= organization_scope(Period).roots.order(from_date: :desc).to_a
    end
    helper_method :years

    def other_budgets
      organization_scope(Budget).newest_first.includes(:period).to_a
    end
    helper_method :other_budgets

    def fill_budget
      case @start
      when "actuals"
        year = years.find { |each| each.id == params[:actuals_period_id].to_i } || raise(ActiveRecord::RecordNotFound)
        @budget.fill_from_actuals!(year, percent: percent)
      when "budget"
        @budget.fill_from_budget!(organization_scope(Budget).find(params[:budget_id]))
      end
    end

    # The percentage to change actual results by ("5", "-2.5", "+10%").
    def percent
      AmountParser.decimal(params[:percent].to_s.strip.delete_suffix("%"), format: number_format) || 0
    rescue ArgumentError
      raise ArgumentError, "#{params[:percent]} isn't a percentage"
    end

    # The amounts typed ({ account_id => { period_id => cents } }) and anything that isn't
    # an amount, by account and month. The budget checks the accounts and months.
    def typed_amounts
      problems = []
      currency = accounting_organization.currency
      months = @budget.months.index_by(&:id)
      accounts = Budget.accounts(accounting_organization).index_by(&:id)
      typed = params.fetch(:amounts, {}).to_unsafe_h.to_h do |account_id, by_month|
        by_month = by_month.is_a?(Hash) ? by_month : {}
        [ account_id.to_i, by_month.to_h do |month_id, text|
          [ month_id.to_i, amount_cents(text, currency) do |problem|
            problems << "#{accounts[account_id.to_i]&.code_with_name || account_id}, #{months[month_id.to_i]&.label || month_id}: #{problem}"
          end.to_i ]
        end ]
      end
      [ typed, problems ]
    end
  end
end
