module TudlaAccounting
  class AccountsController < ApplicationController
    permits :record, only: %i[new create edit update destroy]

    before_action :set_account, only: %i[show edit update destroy]
    helper_method :organization_accounts

    def index
      @accounts = organization_accounts.includes(:contra_account).to_a
      @year = year_for(Time.current) || organization_scope(Period).roots.order(:from_date).last
      @closing = closing_balances(@accounts, @year)
    end

    def show
      @years = organization_scope(Period).roots.order(from_date: :desc)
      @year = (params[:year_id] && @years.find(params[:year_id])) || year_for(Time.current) || @years.first
      return unless @year

      @year_balance = Balance.peek(@account, @year)
      @months = monthly_balances(@year.children.order(:from_date).to_a)
      @ledger = ledger
    end

    def new
      @account = organization_scope(Account).new(currency: accounting_organization.currency, category: params[:category])
      @account.parent = organization_scope(Account).find(params[:parent_id]) if params[:parent_id]
    end

    def create
      @account = organization_scope(Account).new(account_params)
      if @account.save
        redirect_to account_path(@account), notice: "Account #{@account.code_with_name} was created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @account.update(account_params)
        redirect_to account_path(@account), notice: "Account #{@account.code_with_name} was updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      if @account.destroy
        redirect_to accounts_path, notice: "Account #{@account.code_with_name} was deleted."
      else
        redirect_to account_path(@account), alert: @account.errors.full_messages.to_sentence
      end
    end

    private

    def organization_accounts
      organization_scope(Account).order(:code)
    end

    def set_account
      @account = organization_scope(Account).find(params[:id])
    end

    # Parent and contra accounts can only be the organization's own.
    def account_params
      permitted = params.require(:account).permit(:code, :name, :category, :currency, :parent_id, :contra_account_id, :cash_flow_activity)
      %i[parent_id contra_account_id].each do |key|
        permitted[key] = organization_scope(Account).find(permitted[key]).id if permitted[key].present?
      end
      permitted
    end

    def year_for(time)
      Period.periods_for_date(accounting_organization, time).roots.first
    end

    # [month, balance] for each month in order, as Balance.peek would give them: a month
    # with nothing posted opens and closes where the one before it closed (the first at
    # the year's opening).
    def monthly_balances(months)
      stored = Balance.where(account: @account, period: months).index_by(&:period_id)
      running = @year_balance.starting_amount_cents
      months.map do |month|
        balance = stored[month.id] || Balance.new(account: @account, period: month, organization: accounting_organization, currency: accounting_organization.currency,
                                                  starting_amount_cents: running, current_amount_cents: 0, ending_amount_cents: running)
        running = balance.ending_amount_cents
        [ month, balance ]
      end
    end

    # Closing balance of each account for the year, read without storing anything.
    def closing_balances(accounts, year)
      return {} unless year

      Balance.peek_all(accounts, year).transform_values(&:ending_amount)
    end

    # Lines posted to the account and its sub-accounts during the year, signed on the
    # account's own side, with a running balance from the year's opening balance.
    def ledger
      from = params[:from].presence&.to_date
      thru = params[:thru].presence&.to_date
      lines = Detail.joins(:entry, :balance)
        .where(account_id: @account.subtree_ids, tudla_accounting_balances: { period_id: @year.subtree_ids })
        .includes(:account, :entry).order("tudla_accounting_entries.posted_at", :id).to_a

      running = @year_balance.starting_amount
      rows = lines.map do |line|
        signed = line.debit? == @account.debit_balance? ? line.amount : -line.amount
        running += signed
        { line: line, debit: (line.amount if line.debit?), credit: (line.amount if line.credit?), balance: running }
      end
      rows.select! { |row| (from.nil? || row[:line].entry.posted_at.to_date >= from) && (thru.nil? || row[:line].entry.posted_at.to_date <= thru) }
      { page: Paginator.new(rows, page: params[:page], per_page: 50), from: from, thru: thru }
    end
  end
end
