require "rails_helper"

RSpec.describe "Tax", type: :service do
  let(:organization) { create(:organization, currency: "AUD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

  before do
    TudlaAccounting::AccountsCreator.call([
      { code: "1100", name: "Receivables", category: "asset" },
      { code: "2100", name: "Payables", category: "liability" },
      { code: "2200", name: "GST", category: "liability" },
      { code: "4000", name: "Sales", category: "income" },
      { code: "4100", name: "Exports", category: "income" },
      { code: "6000", name: "Supplies", category: "expense" }
    ], organization)
  end

  let!(:gst_sales) { TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST on sales", rate: "0.1", kind: :sales, account: account("2200")) }
  let!(:gst_purchases) { TudlaAccounting::TaxCode.create!(organization: organization, code: "GSTP", name: "GST on purchases", rate: "0.1", kind: :purchases, account: account("2200")) }
  let!(:free) { TudlaAccounting::TaxCode.create!(organization: organization, code: "FRE", name: "GST-free", rate: 0, kind: :sales) }

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def aud(amount) = Money.from_amount(BigDecimal(amount.to_s), "AUD")
  def balance(code) = TudlaAccounting::Balance.peek(account(code), year).ending_amount

  def book(particulars, on, details, **options)
    entry = TudlaAccounting::Entry.create_from_ruby_hash({ organization_type: "Organization", organization_id: organization.id, particulars: particulars,
                                                          transacted_at: on.iso8601, details: details }.merge(options))
    entry.post(entry.transacted_at)
    entry
  end

  def lines(entry) = entry.details.map { |d| [ d.account.code, d.tally, d.amount_cents, d.tax_code&.code, d.tax_role ] }

  describe "a tax code" do
    it "works out the tax on an amount, or the tax in it" do
      expect(gst_sales.tax_cents(100_00)).to eq(10_00)
      expect(gst_sales.tax_cents(110_00, inclusive: true)).to eq(10_00)
      expect(gst_sales.tax_cents(1_05)).to eq(11) # 10.5 cents, rounded half up
      expect(gst_sales.label).to eq("GST (10%)")
      expect(TudlaAccounting::TaxCode.new(rate: "0.125", code: "X").label).to eq("X (12.5%)")
    end

    it "needs an account when it has a rate, of the same organization, and a unique code" do
      code = TudlaAccounting::TaxCode.new(organization: organization, code: "GST", name: "Again", rate: "0.1", kind: :sales)
      expect(code).not_to be_valid
      expect(code.errors.full_messages).to include("Code has already been taken", "Account is needed for a code with a rate")

      other = create(:organization)
      TudlaAccounting::AccountsCreator.call([ { code: "2200", name: "GST", category: "liability" } ], other)
      code = TudlaAccounting::TaxCode.new(organization: organization, code: "NEW", name: "New", rate: "0.1", kind: :sales,
                                          account: TudlaAccounting::Account.find_by(organization: other, code: "2200"))
      expect(code.errors.tap { code.valid? }.full_messages).to eq([ "Account must belong to the same organization" ])
    end
  end

  describe "entries" do
    it "adds the tax on a line to the code's account, on the same side" do
      sale = book("Invoice 1", Time.zone.local(2026, 2, 3), [
        { account_code: "1100", amount: "AUD 110.00" }, { account_code: "4000", amount: "AUD 100.00", tax_code: "GST" }
      ])
      expect(lines(sale)).to contain_exactly([ "1100", "debit", 110_00, nil, nil ], [ "4000", "credit", 100_00, "GST", "base" ], [ "2200", "credit", 10_00, "GST", "tax" ])
      expect(balance("2200")).to eq(aud(10))
    end

    it "splits a tax-inclusive amount into the line and its tax" do
      bill = book("Bill 1", Time.zone.local(2026, 2, 4), [
        { account_code: "6000", amount: "AUD 55.00", tax_code: "GSTP" }, { account_code: "2100", amount: "AUD 55.00" }
      ], tax_inclusive: true)
      expect(lines(bill)).to contain_exactly([ "6000", "debit", 50_00, "GSTP", "base" ], [ "2200", "debit", 5_00, "GSTP", "tax" ], [ "2100", "credit", 55_00, nil, nil ])
    end

    it "tags a zero-rated line without adding a tax line, and keeps tags on a reversal" do
      export = book("Export", Time.zone.local(2026, 2, 5), [ { account_code: "1100", amount: "AUD 300.00" }, { account_code: "4100", amount: "AUD 300.00", tax_code: "FRE" } ])
      expect(lines(export)).to contain_exactly([ "1100", "debit", 300_00, nil, nil ], [ "4100", "credit", 300_00, "FRE", "base" ])

      reversal = export.reverse!(on: Date.new(2026, 2, 6))
      expect(lines(reversal)).to contain_exactly([ "1100", "credit", 300_00, nil, nil ], [ "4100", "debit", 300_00, "FRE", "base" ])
    end

    describe "on a line with a foreign amount" do
      before { TudlaAccounting::AccountsCreator.call([ { code: "4200", name: "Sales EUR", category: "income", currency: "EUR" } ], organization) }

      def foreign(entry) = entry.details.filter_map { |d| d.foreign_exchange && [ d.account.code, d.foreign_exchange.other_currency_cents ] }

      it "taxes the converted amount, in the organization's currency" do
        sale = book("Export", Time.zone.local(2026, 2, 3), [
          { account_code: "1100", amount: "AUD 176.00" },
          { account_code: "4200", amount: "AUD 160.00", tax_code: "GST", fx: { other_currency_amount: "EUR 100.00", fx_rate: "1.6" } }
        ])
        expect(lines(sale)).to contain_exactly([ "1100", "debit", 176_00, nil, nil ], [ "4200", "credit", 160_00, "GST", "base" ], [ "2200", "credit", 16_00, "GST", "tax" ])
        expect(foreign(sale)).to eq([ [ "4200", 100_00 ] ]) # the tax line has no foreign amount
      end

      it "splits the foreign amount too when the amounts include the tax" do
        sale = book("Export", Time.zone.local(2026, 2, 3), [
          { account_code: "1100", amount: "AUD 176.00" },
          { account_code: "4200", amount: "AUD 176.00", tax_code: "GST", fx: { other_currency_amount: "EUR 110.00", fx_rate: "1.6" } }
        ], tax_inclusive: true)
        expect(lines(sale)).to contain_exactly([ "1100", "debit", 176_00, nil, nil ], [ "4200", "credit", 160_00, "GST", "base" ], [ "2200", "credit", 16_00, "GST", "tax" ])
        expect(foreign(sale)).to eq([ [ "4200", 100_00 ] ])
        expect(TudlaAccounting::TaxReport.call(organization, from: Time.zone.local(2026, 2, 1), thru: Time.zone.local(2026, 2, 28).end_of_day)[:sales])
          .to eq(base: aud(160), tax: aud(16))
      end
    end

    it "refuses an unknown code, a tax account in another currency, and a tax line on another account" do
      details = [ { account_code: "1100", amount: "AUD 110.00" }, { account_code: "4000", amount: "AUD 100.00", tax_code: "NOPE" } ]
      expect { book("Bad", Time.zone.local(2026, 2, 3), details) }.to raise_error(ArgumentError, "invalid tax_code: NOPE")

      TudlaAccounting::AccountsCreator.call([ { code: "2210", name: "VAT EUR", category: "liability", currency: "EUR" } ], organization)
      TudlaAccounting::TaxCode.create!(organization: organization, code: "VAT", name: "VAT", rate: "0.2", kind: :sales, account: account("2210"))
      details = [ { account_code: "1100", amount: "AUD 120.00" }, { account_code: "4000", amount: "AUD 100.00", tax_code: "VAT" } ]
      expect { book("Bad", Time.zone.local(2026, 2, 3), details) }.to raise_error(ArgumentError, "the VAT tax account is held in EUR; tax is posted in AUD")

      line = TudlaAccounting::Detail.new(organization: organization, account: account("4000"), tax_code: gst_sales, tax_role: :tax, amount_cents: 1, tally: :credit)
      expect(line.errors.tap { line.valid? }[:account]).to include("must be the tax code's account for a tax line")
      expect(TudlaAccounting::Detail.new(tax_code: gst_sales).tap(&:valid?).errors[:tax_role]).to include("can't be blank")
      line = TudlaAccounting::Detail.new(organization: create(:organization), tax_code: gst_sales, tax_role: :base)
      expect(line.errors.tap { line.valid? }[:tax_code]).to include("must belong to the same organization")
    end
  end

  describe "the report" do
    def report(from, thru) = TudlaAccounting::TaxReport.call(organization, from: from, thru: thru)

    before do
      book("Invoice 1", Time.zone.local(2026, 2, 3), [ { account_code: "1100", amount: "AUD 110.00" }, { account_code: "4000", amount: "AUD 100.00", tax_code: "GST" } ])
      book("Export", Time.zone.local(2026, 2, 5), [ { account_code: "1100", amount: "AUD 300.00" }, { account_code: "4100", amount: "AUD 300.00", tax_code: "FRE" } ])
      book("Bill 1", Time.zone.local(2026, 2, 10), [ { account_code: "6000", amount: "AUD 55.00", tax_code: "GSTP" }, { account_code: "2100", amount: "AUD 55.00" } ], tax_inclusive: true)
      credit = book("Credit note", Time.zone.local(2026, 2, 20), [ { account_code: "1100", amount: "AUD -22.00" }, { account_code: "4000", amount: "AUD -20.00", tax_code: "GST" } ])
      expect(lines(credit)).to include([ "2200", "debit", 2_00, "GST", "tax" ])
      book("Invoice 2", Time.zone.local(2026, 4, 1), [ { account_code: "1100", amount: "AUD 1100.00" }, { account_code: "4000", amount: "AUD 1000.00", tax_code: "GST" } ])
    end

    it "shows what was taxed under each code and the tax, net of credit notes, in the span" do
      result = report(Time.zone.local(2026, 1, 1), Time.zone.local(2026, 3, 31).end_of_day)

      expect(result[:codes].map { |row| [ row[:tax_code].code, row[:base], row[:tax] ] })
        .to eq([ [ "FRE", aud(300), aud(0) ], [ "GST", aud(80), aud(8) ], [ "GSTP", aud(50), aud(5) ] ])
      expect(result[:sales]).to eq(base: aud(380), tax: aud(8))
      expect(result[:purchases]).to eq(base: aud(50), tax: aud(5))
      expect(result[:net_tax]).to eq(aud(3))
      expect(result[:net_tax]).to eq(TudlaAccounting::Balance.peek(account("2200"), year.children.order(:from_date).third).ending_amount) # what the GST account holds
    end

    it "lists inactive codes only when something was posted under them" do
      free.update!(active: false)
      expect(report(Time.zone.local(2026, 4, 1), Time.zone.local(2026, 4, 30).end_of_day)[:codes].map { |row| row[:tax_code].code }).to eq(%w[GST GSTP])
      expect(report(Time.zone.local(2026, 2, 1), Time.zone.local(2026, 2, 28).end_of_day)[:codes].map { |row| row[:tax_code].code }).to eq(%w[FRE GST GSTP])
    end
  end
end
