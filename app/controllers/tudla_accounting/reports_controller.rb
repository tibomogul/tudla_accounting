module TudlaAccounting
  class ReportsController < ApplicationController
    include ReportPeriods

    GENERAL_LEDGER_PAGE = 500 # lines

    for_country :books_of_accounts, only: %i[books books_sample]
    for_country :summary_lists, only: %i[sales_list purchases_list]
    for_country :withholding_reports, only: %i[withholding qap sawt supplier_certificates]
    for_country :payee_payments, only: :payee_payments
    for_country :taxable_payments, only: :taxable_payments

    # The general reports, then each country's for books that are that country's (or have
    # no country; see Jurisdictions): the Philippines' when it can have them, Australia's
    # once they'd show something.
    def index
      @books_of_accounts = Jurisdictions.on?(accounting_organization, :books_of_accounts)
      @summary_lists = Jurisdictions.on?(accounting_organization, :summary_lists)
      @withholding = Jurisdictions.on?(accounting_organization, :withholding_reports) && organization_scope(WithholdingCode).exists?
      @withheld_on_payment = Jurisdictions.on?(accounting_organization, :payee_payments) && organization_scope(WithholdingCode).on_payment.exists?
      @taxable_payments = Jurisdictions.on?(accounting_organization, :taxable_payments) && Reports::TaxablePayments.any_marked?(accounting_organization)
    end

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

      @tax_return_forms = organization_scope(TaxReturnForm).order(:name).to_a
      @report = TaxReport.call(accounting_organization, from: @from.from_date, thru: @thru.thru_date,
                               basis: params[:basis].presence_in(TaxReport::BASES.map(&:to_s)))
      respond_with_table("tax-summary-#{@report[:basis]}-#{span_name}") { Reports::Tables.tax(@report) }
    end

    # A tax return form's boxes (form_id; the first form by default) for a run of months
    # (this month by default) on a basis, as TaxReturnCalculator works them out.
    def tax_return
      @forms = organization_scope(TaxReturnForm).order(:name).to_a
      return respond_with_table("tax-return") if @forms.empty? || !month_range

      @form = params[:form_id].present? ? (@forms.find { |form| form.id == params[:form_id].to_i } || raise(ActiveRecord::RecordNotFound)) : @forms.first
      @report = TaxReturnCalculator.call(@form, from: @from.from_date, thru: @thru.thru_date, basis: params[:basis].presence_in(TaxReport::BASES.map(&:to_s)))
      @filed = organization_scope(FiledTaxReturn).active.where(form: @form).where("from_date <= ? AND thru_date >= ?", @thru.thru_date, @from.from_date).newest_first.to_a
      respond_with_table("#{@form.name.parameterize}-#{@report[:basis]}-#{span_name}") { Reports::Tables.tax_return(@report) }
    end

    # The tax withheld by code and month over a run of months (this quarter by default).
    def withholding
      return respond_with_table("withholding-summary") unless month_range(quarter: true)

      @report = Reports::Withholding.new(accounting_organization, from: @from, thru: @thru)
      respond_with_table("withholding-summary-#{span_name}") { Reports::Tables.withholding_summary(@report) }
    end

    # The suppliers tax was withheld from, or the customers who withheld it with their
    # certificates in, over a run of months (this quarter by default).
    def qap = withholding_list(:qap)

    # The tax withheld from suppliers when they were paid, by payee, over a run of months
    # (the last financial year by default), for the year-end report and payment summaries.
    def payee_payments
      return respond_with_table("payee-payments") unless month_range(last_year: true)

      @report = Reports::PayeePayments.new(accounting_organization, from: @from, thru: @thru)
      return payment_summaries if request.format.pdf?

      respond_with_table("payee-payments-#{span_name}") { Reports::Tables.payee_payments(@report) }
    end

    # What was paid in the payments marked taxable_payment, by payee, over a run of months
    # (the last financial year by default), for a taxable payments report such as the TPAR.
    def taxable_payments
      return respond_with_table("taxable-payments") unless month_range(last_year: true)

      @report = Reports::TaxablePayments.new(accounting_organization, from: @from, thru: @thru)
      respond_with_table("taxable-payments-#{span_name}") { Reports::Tables.taxable_payments(@report) }
    end

    def sawt = withholding_list(:sawt)

    # What was sold to each customer or bought from each supplier, month by month, over a
    # run of months (this quarter by default).
    def sales_list = summary_list(:sales)
    def purchases_list = summary_list(:purchases)

    # The tax certificates (BIR Form 2307) for the suppliers tax was withheld from in three
    # months: the list, or as a PDF, all of them or (contact_id) one supplier's.
    def supplier_certificates
      three_months
      @quarter_choices = quarter_choices
      @any_codes = organization_scope(WithholdingCode).exists?
      @report = Reports::SupplierCertificates.new(accounting_organization, @quarter) if @quarter
      certificates = @report&.certificates.to_a
      respond_to do |format|
        format.html { @page = Paginator.new(certificates, page: params[:page]) }
        format.pdf do
          chosen = params[:contact_id].present? ? certificates.select { |certificate| certificate.contact.id.to_s == params[:contact_id] } : certificates
          next head(:not_found) if chosen.empty?

          who = params[:contact_id].present? ? chosen.first.contact.name : "all-suppliers"
          send_pdf("BIR-2307-#{who}-#{@quarter.from}-to-#{@quarter.thru}", fallback: reports_supplier_certificates_path(quarter: @quarter.from)) { PdfMaker.supplier_certificates(@report, chosen) }
        end
      end
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

    # One of the books of accounts (book; the general journal by default) over a run of
    # months (this financial year to date by default), a page of the book to a printed
    # page, or as a PDF; or all six as an Excel workbook (Reports::BooksWorkbook). See
    # Reports::BooksOfAccounts.
    def books
      @book_key = params[:book].presence_in(Reports::BooksOfAccounts::BOOKS.keys) || "general_journal"
      if month_range(year_to_date: true)
        @report = Reports::BooksOfAccounts.new(accounting_organization, from: @from, thru: @thru)
        @book = @report.book(@book_key)
      end
      respond_to do |format|
        format.html
        format.pdf do
          next head(:not_found) unless @book

          send_pdf("#{@book.title}-#{span_name}", fallback: request.path) { PdfMaker.book(@report, @book) }
        end
        format.xlsx do
          next head(:not_found) unless @report && TudlaAccounting.xlsx?

          send_data Reports::BooksWorkbook.new(@report).to_xlsx, filename: "books-of-accounts-#{span_name}.xlsx", type: Mime[:xlsx].to_s
        end
      end
    end

    # A page of each book with made-up rows, to show their format (Reports::SampleBooks),
    # for a year (this one by default). It needs no financial year or postings.
    def books_sample
      @book_key = params[:book].presence_in(Reports::BooksOfAccounts::BOOKS.keys) || "general_journal"
      year = params[:year].to_i
      @report = Reports::SampleBooks.new(accounting_organization, year: year.between?(2000, 2100) ? year : Date.current.year)
      @book = @report.book(@book_key)
      respond_to do |format|
        format.html
        format.pdf { send_pdf("Sample-#{@book.title}-#{@report.year}", fallback: request.path) { PdfMaker.book(@report, @book) } }
        format.xlsx do
          next head(:not_found) unless TudlaAccounting.xlsx?

          send_data Reports::BooksWorkbook.new(@report).to_xlsx, filename: "sample-books-of-accounts-#{@report.year}.xlsx", type: Mime[:xlsx].to_s
        end
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
        @deliveries = organization_scope(Delivery).where(subject: party, kind: "statement").newest_first.limit(10).to_a
      end
      name = "statement-#{PartyStatement.party_name(party).parameterize if party}-#{@open_items ? "open-items-#{@thru}" : "#{@from}-to-#{@thru}"}"
      respond_with_table(name, available: !@statement.nil?, pdf: -> { PdfMaker.statements([ @statement ], open_items: @open_items) }) do
        Reports::Tables.party_statement(@statement, open_items: @open_items)
      end
    end

    # Every customer's (or supplier's) statement with something to send, one to a printed
    # page: those with a balance at either end or activity in between, or (open_items) with
    # anything open at the end.
    def statements
      statement_options
      @statements = PartyStatement.to_send(accounting_organization, type: @type, from: @from, thru: @thru, open_items: @open_items)
      name = "statements-#{PartyStatement::PARTY_NAMES.fetch(@type).downcase.pluralize}-#{@open_items ? "open-items-#{@thru}" : "#{@from}-to-#{@thru}"}"
      respond_with_table(name, available: true, pdf: -> { PdfMaker.statements(@statements, open_items: @open_items) }) do
        Reports::Tables.party_statements(@statements, type: @type, open_items: @open_items)
      end
    end

    private

    def withholding_list(list)
      @list = list
      return respond_with_table(list.to_s, html: -> { render :withholding_list }) unless month_range(quarter: true)

      @report = Reports::Withholding.new(accounting_organization, from: @from, thru: @thru)
      respond_with_table("#{list}-#{span_name}", html: -> { render :withholding_list }) { Reports::Tables.public_send(list, @report) }
    end

    # The payees' payment summaries as a PDF: one payee's (contact_id), or all of them.
    def payment_summaries
      one = params[:contact_id].presence
      chosen = one ? @report.payees.select { |payee| payee.contact.id.to_s == one } : @report.payees
      return head(:not_found) if chosen.empty?

      who = one ? chosen.first.contact.name : "all-payees"
      send_pdf("payment-summary-#{who}-#{span_name}", fallback: reports_payee_payments_path(from_id: @from.id, thru_id: @thru.id)) { PdfMaker.payment_summaries(@report, chosen) }
    end

    def summary_list(side)
      @side = side
      name = "#{side}-list"
      return respond_with_table(name, html: -> { render :summary_list }) unless month_range(quarter: true)

      @report = Reports::SummaryLists.new(accounting_organization, from: @from, thru: @thru)
      respond_with_table("#{name}-#{span_name}", html: -> { render :summary_list }) { Reports::Tables.summary_list(@report, side) }
    end

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
    # an Excel workbook when the host has caxlsx, or (pdf, when given) the PDF it makes.
    # Not found when there is nothing to export (no periods yet, say), or no Excel or PDFs.
    # The workbook's sheet is named after the file.
    def respond_with_table(name, available: !@report.nil?, html: nil, pdf: nil, &table)
      respond_to do |format|
        format.html { html&.call }
        format.pdf { pdf && available ? send_pdf(name, fallback: request.path) { pdf.call } : head(:not_found) }
        format.csv { available ? send_data(table.call.to_csv, filename: "#{name}.csv", type: "text/csv") : head(:not_found) }
        format.xlsx do
          next head(:not_found) unless available && TudlaAccounting.xlsx?

          send_data table.call.to_xlsx(name.titleize), filename: "#{name}.xlsx", type: Mime[:xlsx].to_s
        end
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
