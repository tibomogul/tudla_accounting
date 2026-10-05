require "rails_helper"
require_relative "../../support/entry_sources"

RSpec.describe TudlaAccounting::CarryingAmountsCreator, type: :service do
  include_context "with entry source models"

  let(:organization) { create(:organization, currency: "AUD") }
  let(:customer) { create(:organization, name: "Customer") }
  let(:date_prior) { Date.new(2025, 12, 31) }

  before do
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Cash", category: "asset" },
      { code: "1100", name: "Accounts Receivable", category: "asset" },
      { code: "2100", name: "Accounts Payable", category: "liability" },
      { code: "4000", name: "Sales", category: "income" },
      { code: "5000", name: "Purchases", category: "expense" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def aud(amount) = Money.from_amount(BigDecimal(amount.to_s), "AUD")

  def import(file = file_fixture("carrying_amounts.csv"), **options)
    described_class.call(organization: organization, csv_file: file, date_prior: date_prior,
                         sales_account_code: "4000", purchase_account_code: "5000", **options)
  end

  it "opens a carrying amount for every row, with its due date" do
    amounts = import

    expect(amounts.map { |amount| [ amount.carrying_amount_type, amount.amount, amount.due_date.to_date ] }).to eq([
      [ "receivable", aud(1000), Date.new(2026, 1, 15) ],
      [ "payable", aud(500), Date.new(2026, 1, 20) ],
      [ "receivable", aud(154), Date.new(2026, 1, 25) ]
    ])
  end

  it "records each row as an entry dated before the cut-over, marked posted but not changing balances" do
    import
    entry = TudlaAccounting::Entry.find_by(particulars: "Invoice 1001")

    expect(entry).to have_attributes(transacted_at: date_prior.in_time_zone, posted_at: date_prior.in_time_zone)
    expect(entry.details.map { |detail| [ detail.account.code, detail.tally ] }).to contain_exactly([ "1100", "debit" ], [ "4000", "credit" ])
    expect(TudlaAccounting::Balance.count).to eq(0)
    expect { entry.post(Time.zone.local(2026, 1, 1)) }.to raise_error(ArgumentError, "entry is already posted")
  end

  it "puts a foreign-currency row on a sub-account in that currency, with the exchange details" do
    import
    eur = account("1100-EUR")
    amount = TudlaAccounting::CarryingAmount.joins(:detail).find_by(tudla_accounting_details: { account_id: eur.id })

    expect(eur).to have_attributes(parent: account("1100"), currency: "EUR", name: "Accounts Receivable - EUR", category: "asset")
    expect(amount.amount).to eq(aud(154))
    expect(amount.forex).to have_attributes(other_currency: "EUR", other_currency_amount_cents: 100_00,
                                            transaction_rate: BigDecimal("1.54"), conversion_date: Date.new(2025, 12, 20))
    expect(amount.detail.foreign_exchange).to have_attributes(other_currency: "EUR", rate: BigDecimal("1.54"))
  end

  it "reuses an existing currency sub-account" do
    existing = create(:tudla_accounting_account, code: "1150", name: "AR EUR", category: :asset, currency: "EUR",
                                                  organization: organization, parent: account("1100"))
    expect { import }.not_to change { account("1100").children.count }
    expect(TudlaAccounting::Entry.find_by(particulars: "Invoice 1002 (EUR)").details.map(&:account)).to include(existing)
  end

  it "settles like any other receivable when the payment is posted" do
    import
    invoice_entry = TudlaAccounting::Entry.find_by(particulars: "Invoice 1001")
    payment = build(:tudla_accounting_entry, organization: organization, transacted_at: Time.zone.local(2026, 1, 10),
                                             source_type: "Payment", related: invoice_entry)
    payment.details.build(account: account("1000"), tally: :debit, amount_cents: 400_00, currency: "AUD", organization: organization)
    payment.details.build(account: account("1100"), tally: :credit, amount_cents: 400_00, currency: "AUD", organization: organization)
    payment.save!
    payment.post(payment.transacted_at)

    expect(TudlaAccounting::CarryingAmount.find_by(detail: invoice_entry.details.find_by(account: account("1100"))).amount).to eq(aud(600))
  end

  it "links each row to a host record when given a source, taking the related party from it" do
    TudlaAccounting.configuration.related_party_method = :customer

    amounts = import(source: ->(row) { (row[:type] == "receivable" ? Invoice : Bill).create!(customer: customer, due_date: row[:due_date]) })

    expect(amounts.map { |amount| amount.detail.entry.source.class }).to eq([ Invoice, Bill, Invoice ])
    expect(amounts.map(&:related_party)).to all(eq(customer))
  end

  it "uses the organization as the related party without a source" do
    expect(import.map(&:related_party)).to all(eq(organization))
  end

  describe "problems" do
    let(:file) { Rails.root.join("tmp", "carrying_#{SecureRandom.hex(4)}.csv") }

    after { FileUtils.rm_f(file) }

    def import_rows(*rows)
      CSV.open(file, "w") do |csv|
        csv << %w[particulars amount type due_date other_currency other_currency_amount transaction_rate conversion_date]
        rows.each { |row| csv << row }
      end
      import(file.to_s)
    end

    it "imports nothing if any row fails" do
      expect { import_rows([ "Invoice 1", "100", "receivable", "2026-01-15" ], [ "Mystery", "50", "refund", "" ]) }
        .to raise_error(ArgumentError, 'Unknown type "refund" for Mystery; use receivable or payable')
      expect(TudlaAccounting::CarryingAmount.count).to eq(0)
      expect(TudlaAccounting::Entry.count).to eq(0)
    end

    it "rejects an amount that is not a number" do
      expect { import_rows([ "Invoice 1", "lots", "receivable", "" ]) }.to raise_error(ArgumentError, '"lots" is not a number (Invoice 1)')
    end

    it "allows a row without a due date, and treats the organization's own currency as no foreign currency" do
      amount = import_rows([ "Invoice 1", "100", "receivable", "", "aud", "", "", "" ]).sole
      expect(amount).to have_attributes(due_date: nil, forex: nil)
      expect(amount.detail.account).to eq(account("1100"))
    end

    it "needs the receivable account to exist in the organization" do
      account("1100").update!(code: "1199")
      expect { import_rows([ "Invoice 1", "100", "receivable", "" ]) }.to raise_error(ArgumentError, "Receivable account 1100 not found")
    end
  end

  describe "settings" do
    include_context "with isolated TudlaAccounting configuration"

    it "needs receivable and payable account codes configured" do
      TudlaAccounting.configuration.payable_account_code = nil
      expect { import }.to raise_error(ArgumentError, "TudlaAccounting.configuration.payable_account_code is not set")
    end

    it "needs sales and purchase account codes" do
      expect { described_class.new(organization: organization, csv_file: "x", date_prior: date_prior, sales_account_code: "4000", purchase_account_code: nil) }
        .to raise_error(ArgumentError, "No purchase account code given")
    end
  end
end
