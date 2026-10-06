require "rails_helper"

RSpec.describe "Bank reconciliation", type: :service do
  let(:organization) { create(:organization, currency: "AUD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

  before do
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1001", name: "Bank EUR", category: "asset", currency: "EUR" },
      { code: "1100", name: "Receivables", category: "asset" }, { code: "3000", name: "Capital", category: "equity" },
      { code: "6100", name: "Bank fees", category: "expense" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def on(month, day) = Time.zone.local(2026, month, day)
  def bank = account("1000")
  def reconciler = TudlaAccounting::BankReconciler.new(bank)

  def csv(text)
    file = Tempfile.new([ "statement", ".csv" ])
    file.write(text)
    file.flush
    file.path
  end

  def import(text, into: bank, **options) = TudlaAccounting::BankStatementImporter.call(into, csv(text), **options)

  def post(debit, credit, cents, at, particulars: "Entry", fx: nil)
    entry = build(:tudla_accounting_entry, organization: organization, transacted_at: at, particulars: particulars)
    debit_line = entry.details.build(account: account(debit), tally: :debit, amount_cents: cents, currency: "AUD", organization: organization)
    entry.details.build(account: account(credit), tally: :credit, amount_cents: cents, currency: "AUD", organization: organization)
    debit_line.build_foreign_exchange(other_currency: "EUR", other_currency_cents: fx, rate: BigDecimal(cents) / fx) if fx
    entry.save!
    entry.post(at)
    entry.details.find { |detail| detail.account.code.start_with?("100") }
  end

  describe "importing a statement" do
    it "reads dates, descriptions, signed amounts, references and balances, and skips what it has" do
      text = <<~CSV
        Date,Description,Amount,Reference,Balance
        02/03/2026,Deposit from Globex,"1,100.00",INV-7,"1,100.00"
        03/03/2026,Monthly fee,(5.00),,"1,095.00"
        03/03/2026,Monthly fee,(5.00),,"1,090.00"

        2026-03-05,Card purchase,-20.50,,"1,069.50"
      CSV
      expect(import(text)).to eq(imported: 4, skipped: 0)
      expect(import(text)).to eq(imported: 0, skipped: 4)

      lines = TudlaAccounting::BankStatementLine.order(:id)
      expect(lines.map { |l| [ l.occurred_on, l.description, l.amount_cents, l.reference, l.balance_cents, l.currency ] }).to eq([
        [ Date.new(2026, 3, 2), "Deposit from Globex", 1_100_00, "INV-7", 1_100_00, "AUD" ], [ Date.new(2026, 3, 3), "Monthly fee", -5_00, nil, 1_095_00, "AUD" ],
        [ Date.new(2026, 3, 3), "Monthly fee", -5_00, nil, 1_090_00, "AUD" ], [ Date.new(2026, 3, 5), "Card purchase", -20_50, nil, 1_069_50, "AUD" ]
      ])
      expect(lines.first.label).to eq("2 Mar 2026 Deposit from Globex 1,100.00")
      expect(lines.second.label).to eq("3 Mar 2026 Monthly fee (5.00)")
      expect(TudlaAccounting::AuditEvent.where(action: "bank_statement.imported").last.details).to eq("imported" => 0, "skipped" => 4)
    end

    it "takes money in and out columns, month-first dates, the bank's own ids, and the account's currency" do
      text = <<~CSV
        Transaction ID,Posted Date,Payee,Money In,Money Out
        T1,03/02/2026,Client,250.00,
        T2,03/04/2026,,,€12.00
      CSV
      expect(import(text, into: account("1001"), date_order: :mdy)).to eq(imported: 2, skipped: 0)
      expect(TudlaAccounting::BankStatementLine.order(:id).map { |l| [ l.occurred_on, l.description, l.amount_cents, l.currency, l.external_id ] })
        .to eq([ [ Date.new(2026, 3, 2), "Client", 250_00, "EUR", "id:T1" ], [ Date.new(2026, 3, 4), "(no description)", -12_00, "EUR", "id:T2" ] ])
    end

    it "says what is wrong with a file" do
      expect { import("Description,Amount\nx,1\n") }.to raise_error(ArgumentError, "The file needs a Date column")
      expect { import("Date,Amount\n2026-03-01,1\n") }.to raise_error(ArgumentError, "The file needs a Description column")
      expect { import("Date,Description\n2026-03-01,x\n") }.to raise_error(ArgumentError, "The file needs an Amount column, or money in and money out columns")
      expect { import("Date,Description,Amount\nsoon,x,1\n") }.to raise_error(ArgumentError, "Row 2 has a date that can't be read: soon")
      expect { import("Date,Description,Amount\n2026-03-01,x,lots\n") }.to raise_error(ArgumentError, "Row 2 has an amount that can't be read: lots")
      expect { import("Date,Description,Amount\n2026-03-01,x,0.00\n") }.to raise_error(ArgumentError, "Row 2 has no amount")
      expect { import("Date,Description,Amount\n", date_order: :ymd) }.to raise_error(ArgumentError, "date_order must be :dmy or :mdy")
      expect(TudlaAccounting::BankStatementLine.count).to eq(0)
    end
  end

  describe "matching" do
    let!(:deposit) { post("1000", "3000", 1_100_00, on(3, 1), particulars: "Capital") }
    let!(:fee_in_books) { post("6100", "1000", 5_00, on(3, 3), particulars: "Fee") }
    let!(:cheque) { post("6100", "1000", 40_00, on(3, 28), particulars: "Cheque 12") }

    before do
      import(<<~CSV)
        Date,Description,Amount,Balance
        2026-03-02,Deposit,1100.00,1100.00
        2026-03-03,Monthly fee,-5.00,1095.00
        2026-03-04,Interest,0.80,1095.80
      CSV
    end

    def line(description) = TudlaAccounting::BankStatementLine.find_by!(description: description)

    it "suggests ledger lines for the same amount within a week, and matches them" do
      expect(reconciler.suggestions.transform_keys(&:description)).to eq("Deposit" => deposit, "Monthly fee" => fee_in_books)
      expect(reconciler.match_suggestions!).to eq(2)
      expect(line("Deposit").details).to eq([ deposit ])
      expect(reconciler.suggestions).to be_empty
      expect(reconciler.unmatched_ledger).to eq([ cheque ])
    end

    it "matches one statement line to several ledger lines that add up to it, and unmatches it" do
      split = post("1000", "3000", 60_00, on(3, 2))
      rest = post("1000", "3000", 40_00, on(3, 2))
      import("Date,Description,Amount\n2026-03-02,Two deposits,100.00\n")

      reconciler.match!(line("Two deposits"), [ split, rest ])
      expect(line("Two deposits")).to be_matched
      expect(TudlaAccounting::AuditEvent.where(action: "bank_line.matched").last.subject_label).to eq("2 Mar 2026 Two deposits 100.00")

      reconciler.unmatch!(line("Two deposits"))
      expect(line("Two deposits")).not_to be_matched
      expect { reconciler.unmatch!(line("Two deposits")) }.to raise_error(ArgumentError, "That statement line isn't matched")
    end

    it "refuses matches that don't fit" do
      other = TudlaAccounting::BankReconciler.new(account("1100"))
      draft = build(:tudla_accounting_entry, organization: organization, transacted_at: on(3, 2)).tap do |entry|
        entry.details.build(account: bank, tally: :debit, amount_cents: 1_100_00, currency: "AUD", organization: organization)
        entry.details.build(account: account("3000"), tally: :credit, amount_cents: 1_100_00, currency: "AUD", organization: organization)
        entry.save!
      end.details.find(&:debit?)

      {
        -> { other.match!(line("Deposit"), [ deposit ]) } => "That statement line is for another account",
        -> { reconciler.match!(line("Deposit"), []) } => "Choose the ledger lines it matches",
        -> { reconciler.match!(line("Deposit"), [ draft ]) } => "Only posted lines on 1000 - Bank can be matched",
        -> { reconciler.match!(line("Deposit"), [ fee_in_books ]) } => "The ledger lines add up to AUD -5.00 but the statement line is AUD 1,100.00"
      }.each { |attempt, message| expect(&attempt).to raise_error(ArgumentError, message) }

      reconciler.match!(line("Deposit"), [ deposit ])
      expect { reconciler.match!(line("Deposit"), [ deposit ]) }.to raise_error(ArgumentError, "That statement line is matched already")
      import("Date,Description,Amount\n2026-03-02,Again,1100.00\n")
      expect { reconciler.match!(line("Again"), [ deposit ]) }.to raise_error(ArgumentError, "A ledger line is matched to another statement line already")
    end

    it "offers the closest ledger lines moving money the same way within 60 days to match by hand" do
      stub_const("TudlaAccounting::BankReconciler::MATCH_CANDIDATE_LIMIT", 1)
      far = post("6100", "1000", 7_00, on(5, 30), particulars: "Far")
      expect(reconciler.candidates_for(line("Monthly fee"))).to eq([ fee_in_books ])
      expect(reconciler.candidates_for(line("Deposit"))).to eq([ deposit ])
      stub_const("TudlaAccounting::BankReconciler::MATCH_CANDIDATE_LIMIT", 10)
      expect(reconciler.candidates_for(line("Monthly fee"))).to eq([ fee_in_books, cheque ]) # not the one 88 days away
      expect(reconciler.candidates_for(line("Monthly fee"))).not_to include(far)
    end

    it "posts an entry for a line the books don't have, and matches it" do
      entry = reconciler.create_entry!(line("Interest"), account: account("3000"), particulars: "Interest March")
      expect(entry).to have_attributes(particulars: "Interest March", transacted_at: on(3, 4), posted_at: on(3, 4))
      expect(entry.details.map { |d| [ d.account.code, d.tally, d.amount_cents ] }).to contain_exactly([ "1000", "debit", 80 ], [ "3000", "credit", 80 ])
      expect(line("Interest").details.map(&:entry)).to eq([ entry ])

      fee = reconciler.create_entry!(TudlaAccounting::BankStatementLine.create!(organization: organization, account: bank, occurred_on: Date.new(2026, 3, 9),
                                                                                description: "Card fee", amount_cents: -2_00, currency: "AUD", external_id: "x"),
                                     account: account("6100"))
      expect(fee.particulars).to eq("Card fee")
      expect(fee.details.find { |d| d.account == bank }).to be_credit

      expect { reconciler.create_entry!(line("Interest"), account: account("3000")) }.to raise_error(ArgumentError, "That statement line is matched already")
      expect { reconciler.create_entry!(line("Deposit"), account: bank) }.to raise_error(ArgumentError, "Choose another account than the bank account")
    end

    it "sums up where the books and the bank stand on a date" do
      reconciler.match_suggestions!

      summary = reconciler.summary(as_of: Date.new(2026, 3, 31))
      aud = ->(amount) { Money.from_amount(BigDecimal(amount.to_s), "AUD") }
      expect(summary).to include(book_balance: aud.call(1_055), unmatched_ledger: aud.call(-40), unmatched_statement: aud.call("0.80"),
                                 expected_statement_balance: aud.call("1095.80"), statement_balance: aud.call("1095.80"),
                                 statement_balance_on: Date.new(2026, 3, 4), difference: aud.call(0))
      expect(reconciler.summary(as_of: Date.new(2026, 3, 1))).to include(book_balance: aud.call(1_100), statement_balance: nil, difference: nil)
    end

    it "counts the opening balance of a liability (a credit card) as money owed" do
      TudlaAccounting::AccountsCreator.call([ { code: "2300", name: "Card", category: "liability" } ], organization)
      TudlaAccounting::StartingBalanceCreator.call(organization, Date.new(2026, 1, 1), [ { account_id: account("2300").id, amount_cents: 300_00 } ], "AUD")
      expect(TudlaAccounting::BankReconciler.new(account("2300")).summary(as_of: Date.new(2026, 1, 31))[:book_balance]).to eq(Money.new(-300_00, "AUD"))
    end
  end

  describe "posting entries for a foreign-currency account" do
    let(:eur) { TudlaAccounting::BankReconciler.new(account("1001")) }

    before do
      TudlaAccounting::AccountsCreator.call([ { code: "1101", name: "Receivables EUR", category: "asset", currency: "EUR" } ], organization)
      import(<<~CSV, into: account("1001"))
        Date,Description,Amount
        2026-03-10,Bank fee,-12.00
        2026-03-11,Customer paid,100.00
      CSV
    end

    def line(description) = TudlaAccounting::BankStatementLine.find_by!(description: description)
    def lines(entry) = entry.details.map { |d| [ d.account.code, d.tally, d.amount_cents, d.foreign_exchange&.other_currency_cents, d.foreign_exchange&.rate ] }

    it "converts at a given rate, the bank line carrying the statement amount, and matches it" do
      fee = eur.create_entry!(line("Bank fee"), account: account("6100"), rate: "1.6")
      expect(lines(fee)).to contain_exactly([ "1001", "credit", 19_20, 12_00, BigDecimal("1.6") ], [ "6100", "debit", 19_20, nil, nil ])
      expect(line("Bank fee").details).to eq([ fee.details.find { |d| d.account.code == "1001" } ])
    end

    it "uses the provider's rate for the day, and gives the other line the foreign amount too when it is held in the same currency" do
      TudlaAccounting::ForexRate.create!(from: "EUR", to: "AUD", year: 2026, month: 3, day: 11, rate: BigDecimal("1.65"))
      paid = eur.create_entry!(line("Customer paid"), account: account("1101"))
      expect(lines(paid)).to contain_exactly([ "1001", "debit", 165_00, 100_00, BigDecimal("1.65") ], [ "1101", "credit", 165_00, 100_00, BigDecimal("1.65") ])
    end

    it "explains when it has no rate, or a bad one" do
      expect { eur.create_entry!(line("Bank fee"), account: account("6100")) }.to raise_error(ArgumentError, "No EUR rate for 10 Mar 2026; enter one")
      expect { eur.create_entry!(line("Bank fee"), account: account("6100"), rate: "lots") }.to raise_error(ArgumentError, "The rate lots isn't a number")
      expect { eur.create_entry!(line("Bank fee"), account: account("6100"), rate: "0") }.to raise_error(ArgumentError, "The rate must be more than zero")
      expect(line("Bank fee")).not_to be_matched
    end
  end

  describe "a foreign-currency account" do
    let(:eur) { TudlaAccounting::BankReconciler.new(account("1001")) }

    it "compares ledger lines by their foreign amount, and gives no book balance" do
      received = post("1001", "3000", 160_00, on(3, 2), fx: 100_00)
      bare = post("1001", "3000", 10_00, on(3, 2))
      import("Date,Description,Amount\n2026-03-02,Transfer,100.00\n", into: account("1001"))

      expect(eur.bank_cents(received)).to eq(100_00)
      expect(eur.bank_cents(bare)).to be_nil
      expect(eur.suggestions.values).to eq([ received ])
      line = TudlaAccounting::BankStatementLine.sole
      expect { eur.match!(line, [ bare ]) }.to raise_error(ArgumentError, "A ledger line has no EUR amount to compare")
      expect(eur.summary(as_of: Date.new(2026, 3, 31))).to include(book_balance: nil, unmatched_statement: Money.new(100_00, "EUR"), difference: nil)
    end
  end
end
