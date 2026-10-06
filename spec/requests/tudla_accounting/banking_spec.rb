require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Banking", type: :request do
  include_context "with isolated TudlaAccounting configuration"

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, currency: "AUD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

  before do
    sign_in_as(organization)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1001", name: "Bank EUR", category: "asset", currency: "EUR" },
      { code: "3000", name: "Capital", category: "equity" }, { code: "6100", name: "Bank fees", category: "expense" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def bank = account("1000")
  def line(description) = TudlaAccounting::BankStatementLine.find_by!(description: description)
  def total(name) = css_select("[data-total=#{name}]").first.text.squish
  def statement(text) = Rack::Test::UploadedFile.new(StringIO.new(text), "text/csv", original_filename: "statement.csv")

  def post_entry(debit, credit, cents, at, particulars)
    entry = build(:tudla_accounting_entry, organization: organization, transacted_at: at, particulars: particulars)
    entry.details.build(account: account(debit), tally: :debit, amount_cents: cents, currency: "AUD", organization: organization)
    entry.details.build(account: account(credit), tally: :credit, amount_cents: cents, currency: "AUD", organization: organization)
    entry.save!
    entry.post(at)
    entry
  end

  it "lists the accounts that can be reconciled" do
    get routes.banking_path
    expect(response.body).to include("No statements imported yet.")
    expect(css_select("#other-accounts ~ ul a").map(&:text)).to eq([ "1000 - Bank", "1001 - Bank EUR" ])
  end

  context "with a statement imported" do
    let!(:capital) { post_entry("1000", "3000", 1_000_00, Time.zone.local(2026, 3, 1), "Capital") }
    let!(:cheque) { post_entry("6100", "1000", 30_00, Time.zone.local(2026, 3, 20), "Cheque 7") }

    before do
      post routes.banking_import_path(bank), params: { file: statement(<<~CSV), date_order: "dmy" }
        Date,Description,Amount,Balance
        02/03/2026,Deposit,1000.00,1000.00
        05/03/2026,Account fee,-4.00,996.00
      CSV
    end

    it "imports it, says so, and lists the account with what is left to match" do
      expect(response).to redirect_to(routes.banking_account_path(bank))
      expect(flash[:notice]).to eq("Imported 2 statement lines.")
      post routes.banking_import_path(bank), params: { file: statement("Date,Description,Amount,Balance\n02/03/2026,Deposit,1000.00,1000.00\n") }
      expect(flash[:notice]).to eq("Imported 0 statement lines; 1 already imported.")

      get routes.banking_path
      expect(css_select("tbody tr").first.css("td").map { |cell| cell.text.squish }).to eq([ "1000 - Bank", "2", "5 Mar 2026", "2" ])
    end

    it "shows where the books and the bank stand, suggests a match, and matches the suggestions" do
      get routes.banking_account_path(bank, as_of: "2026-03-31")
      expect([ total("book_balance"), total("unmatched_ledger"), total("unmatched_statement"), total("expected_statement_balance"), total("statement_balance") ])
        .to eq([ "970.00", "970.00", "996.00", "996.00", "996.00" ]) # the unmatched items explain the whole difference
      expect(response.body).to include("Suggested: <a", "Match 1 suggestion", "Reconciled: the books agree with the bank")
      expect(css_select("#ledger-heading ~ div tbody tr").size).to eq(2)

      post routes.banking_match_suggestions_path(bank)
      expect(flash[:notice]).to eq("Matched 1 statement line.")
      post routes.banking_match_suggestions_path(bank)
      expect(flash[:notice]).to eq("Nothing to match.")
    end

    it "posts an entry for a line the books don't have, then reconciles" do
      post routes.banking_match_suggestions_path(bank)
      post routes.create_entry_bank_statement_line_path(line("Account fee")), params: { counter_account_id: account("6100").id, particulars: "Fee March" }
      expect(flash[:notice]).to eq("Posted Fee March and matched it.")

      get routes.banking_account_path(bank, as_of: "2026-03-31")
      expect([ total("book_balance"), total("unmatched_ledger"), total("expected_statement_balance") ]).to eq([ "966.00", "(30.00)", "996.00" ])
      expect(response.body).to include("Reconciled: the books agree with the bank")
      expect(response.body).to include("Every statement line is matched.")

      get routes.banking_account_path(bank, show: "all")
      expect(css_select("tbody tr button").map(&:text)).to include("Unmatch")
    end

    it "matches by hand, unmatches, and explains what it can't do" do
      post routes.match_bank_statement_line_path(line("Account fee")), params: { detail_ids: [ cheque.details.find { |d| d.account == bank }.id ] }
      expect(flash[:alert]).to eq("It was not matched: the ledger lines add up to AUD -30.00 but the statement line is AUD -4.00.")

      deposit_line = capital.details.find { |d| d.account == bank }
      post routes.match_bank_statement_line_path(line("Deposit"), show: "all"), params: { detail_ids: [ deposit_line.id ] }
      expect(response).to redirect_to(routes.banking_account_path(bank, show: "all"))
      expect(flash[:notice]).to eq("Matched Deposit.")

      post routes.unmatch_bank_statement_line_path(line("Deposit"))
      expect(flash[:notice]).to eq("Took the match off Deposit.")
      post routes.unmatch_bank_statement_line_path(line("Deposit"))
      expect(flash[:alert]).to eq("That statement line isn't matched.")

      post routes.create_entry_bank_statement_line_path(line("Deposit")), params: { counter_account_id: bank.id }
      expect(flash[:alert]).to eq("No entry was posted: choose another account than the bank account.")

      get routes.activity_path(kind: "bank_line")
      expect(css_select("tbody td:last-child").map { |cell| cell.text.squish })
        .to eq([ "Unmatched the statement line 2 Mar 2026 Deposit 1,000.00", "Matched the statement line 2 Mar 2026 Deposit 1,000.00" ])
      get routes.activity_path(kind: "bank_statement")
      expect(css_select("tbody td:last-child").first.text.squish).to eq("Imported a statement for 1000 - Bank: 2 lines new, 0 already there")
    end

    it "pages the ledger lines not yet on a statement" do
      22.times { |i| post_entry("6100", "1000", 1_00, Time.zone.local(2026, 4, 1 + i), "Small #{i}") }
      stub_const("TudlaAccounting::BankingController::LEDGER_PAGE", 20)
      get routes.banking_account_path(bank)
      expect(css_select("#ledger-heading ~ div tbody tr").size).to eq(20)
      get routes.banking_account_path(bank, ledger_page: 2)
      expect(css_select("#ledger-heading ~ div tbody tr").size).to eq(4)
      expect(response.body).to include("ledger_page=1")
    end

    it "offers matching and recording for a line without a suggestion" do
      get routes.banking_account_path(bank)
      fee_row = css_select("##{ActionView::RecordIdentifier.dom_id(line('Account fee'))}").first
      expect(fee_row.text).to include("Match or record it", "Record it as spent on")
      expect(fee_row.css("select[name='detail_ids[]'] option").map(&:text)).to eq([ "20 Mar 2026 Cheque 7 -30.00" ])
    end

    it "reports what is wrong with an import" do
      post routes.banking_import_path(bank), params: { file: statement("Description,Amount\nx,1\n") }
      expect(flash[:alert]).to eq("The statement was not imported: the file needs a Date column.")
      post routes.banking_import_path(bank)
      expect(flash[:alert]).to start_with("The statement was not imported: param is missing")
    end

    it "only lets people who can post change it" do
      TudlaAccounting.configuration.authorize = ->(_controller, permission) { permission == :read }
      get routes.banking_account_path(bank)
      expect(response.body).not_to include("Import statement", "Match or record it")
      expect(response.body).to include("Not matched")
      post routes.banking_match_suggestions_path(bank)
      expect(response).to have_http_status(:forbidden)
      post routes.unmatch_bank_statement_line_path(line("Deposit"))
      expect(response).to have_http_status(:forbidden)
    end

    it "refuses another organization's statement line" do
      sign_in_as(create(:organization))
      post routes.unmatch_bank_statement_line_path(line("Deposit"))
      expect(response).to have_http_status(:not_found)
    end
  end

  it "compares only what is unmatched for a foreign-currency account" do
    get routes.banking_account_path(account("1001"))
    expect(response.body).to include("only what is unmatched can be compared", "Bank reconciliation in EUR")
    expect(response.body).not_to include("Record it as")
  end

  it "asks for a statement with balances, and shows when one is out" do
    TudlaAccounting::BankStatementLine.create!(organization: organization, account: bank, occurred_on: Date.new(2026, 3, 1), description: "Deposit",
                                               amount_cents: 5_00, balance_cents: 7_00, currency: "AUD", external_id: "a")
    get routes.banking_account_path(bank, as_of: "2026-03-31")
    expect(response.body).to include("Out by 2.00")
  end

  it "asks for a statement with balances when there is none" do
    get routes.banking_account_path(bank)
    expect(response.body).to include("Import a statement with balances to compare with the bank.", "No statement imported yet.")
  end
end
