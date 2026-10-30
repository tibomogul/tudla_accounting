module TudlaAccounting
  # Reconciling bank accounts: importing statements and matching their lines to the
  # books. See BankStatementImporter and BankReconciler.
  class BankingController < ApplicationController
    LEDGER_PAGE = 100 # ledger lines not yet on a statement, per page
    FORMAT_NAMES = { csv: "CSV", ofx: "OFX", camt053: "CAMT.053" }.freeze
    permits :post, only: %i[import match_suggestions record_by_rules]

    before_action :set_account, only: %i[show import match_suggestions record_by_rules]

    def index
      @accounts = organization_scope(Account).where(category: [ Account::CATEGORY_ASSET, Account::CATEGORY_LIABILITY ]).order(:code)
      @statements = BankStatementLine.where(account: @accounts).group(:account_id).pluck(:account_id, Arel.sql("COUNT(*)"), Arel.sql("MAX(occurred_on)"))
        .to_h { |id, count, last| [ id, { count: count, last: last } ] }
      @unmatched = BankStatementLine.where(account: @accounts).unmatched.group(:account_id).count
    end

    def show
      @reconciler = BankReconciler.new(@account)
      @as_of = params[:as_of].presence&.to_date || Date.current
      @summary = @reconciler.summary(as_of: @as_of)
      @show_all = params[:show] == "all"
      lines = @reconciler.statement_lines.includes(bank_matches: { detail: :entry }).order(occurred_on: :desc, id: :desc)
      @page = Paginator.new(@show_all ? lines : lines.unmatched, page: params[:page])
      @suggestions = @reconciler.suggestions
      @rule_suggestions = @reconciler.rule_suggestions(ledger_suggested: @suggestions.keys)
      @unmatched_ledger = @reconciler.unmatched_ledger.to_a
      @ledger_page = Paginator.new(@unmatched_ledger, page: params[:ledger_page], per_page: LEDGER_PAGE)
      @other_accounts = organization_scope(Account).active.postable.where.not(id: @account.id).order(:code)
      @open_documents = @reconciler.foreign? ? [] : open_documents
    end

    def import
      file = params.require(:file)
      result = BankStatementImporter.call(@account, file.path, date_order: params[:date_order].presence || :dmy, decimal_mark: params[:decimal_mark].presence || ".")
      redirect_to banking_account_path(@account), notice: "Imported #{helpers.pluralize(result[:imported], 'statement line')} from the #{FORMAT_NAMES.fetch(result[:format])} file" \
                                                          "#{"; #{result[:skipped]} already imported" if result[:skipped].positive?}."
    rescue ArgumentError, CSV::MalformedCSVError, ActionController::ParameterMissing => e
      redirect_to banking_account_path(@account), alert: "The statement was not imported: #{e.message.downcase_first}."
    end

    # Records every line a bank rule suggests, by its rule.
    def record_by_rules
      result = BankReconciler.new(@account).record_by_rules!
      flash[:notice] = "Recorded #{helpers.pluralize(result[:recorded].size, 'statement line')} by their rules." if result[:recorded].any?
      flash[:alert] = "Some weren't recorded: #{result[:problems].to_sentence}." if result[:problems].any?
      redirect_to banking_account_path(@account)
    end

    def match_suggestions
      count = BankReconciler.new(@account).match_suggestions!
      redirect_to banking_account_path(@account), notice: count.zero? ? "Nothing to match." : "Matched #{helpers.pluralize(count, 'statement line')}."
    end

    private

    OPEN_DOCUMENTS = 200

    # The approved invoices and bills with something still owed (the latest
    # OPEN_DOCUMENTS), that a statement line can be recorded as paying.
    def open_documents
      organization_scope(Document).approved.where(kind: %w[sales_invoice bill]).with_open_cents.includes(:contact).order(issued_on: :desc, id: :desc)
        .limit(OPEN_DOCUMENTS).to_a.select { |document| document.amount_due.positive? }
    end

    def set_account
      @account = organization_scope(Account).find(params[:account_id])
    end
  end
end
