require "rails_helper"
require "csv"

RSpec.describe TudlaAccounting::ChartOfAccountsLoader, type: :service do
  let(:organization) { create(:organization, currency: "USD") }
  let(:opening_date) { Date.new(2026, 1, 1) }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def opening(code) = TudlaAccounting::Balance.find_by(account: account(code), period: year).starting_amount
  def usd(amount) = Money.from_amount(amount, "USD")

  shared_examples "a chart of accounts loader" do |fixture|
    let(:file) { file_fixture(fixture) }

    it "creates every account with its parent and contra account" do
      expect { described_class.call(organization, file, opening_date) }.to change(TudlaAccounting::Account, :count).by(81)

      expect(account("1010").parent).to eq(account("1000"))
      expect(account("1011").ancestors.map(&:code)).to eq(%w[1000 1010])
      { "1025" => "1020", "1515" => "1510", "2525" => "2520", "4110" => "4010" }.each do |contra, offset|
        expect(account(contra).contra_account).to eq(account(offset))
      end
      expect(account("4010")).to have_attributes(category: "income", currency: "USD")
    end

    it "sets opening balances, with contra accounts on their own side" do
      described_class.call(organization, file, opening_date)

      expect(opening("1000")).to eq(usd(94_000))
      expect(opening("1011")).to eq(usd(25_000))
      expect(opening("1025")).to eq(usd(1_000))  # -1000 in the file: a 1,000 credit allowance
      expect(opening("1010")).to eq(usd(64_000))
      expect(opening("3100")).to eq(usd(-2_000)) # treasury stock: not a contra account, so stays negative
    end

    it "refuses to reload over existing accounts unless overwriting" do
      described_class.call(organization, file, opening_date)
      expect { described_class.call(organization, file, opening_date) }.to raise_error(ArgumentError, /Account 1000 already exists/)
      expect { described_class.call(organization, file, opening_date, true) }.not_to change(TudlaAccounting::Account, :count)
    end
  end

  describe TudlaAccounting::CsvLoader do
    it_behaves_like "a chart of accounts loader", "coa_saas_services.csv"
  end

  describe TudlaAccounting::XlsxLoader do
    it_behaves_like "a chart of accounts loader", "coa_saas_services.xlsx" # codes and amounts stored as numbers
  end

  describe "file problems" do
    let(:file) { Rails.root.join("tmp", "coa_#{SecureRandom.hex(4)}.csv") }

    after { FileUtils.rm_f(file) }

    def load(*rows)
      CSV.open(file, "w") do |csv|
        csv << [ "Account Code", "Account Name", "Account Type", "Contra Code", "Starting Balance", "Parent Account Code" ]
        rows.each { |row| csv << row }
      end
      TudlaAccounting::CsvLoader.call(organization, file.to_s, opening_date)
    end

    it "accepts amounts with thousands separators and cents" do
      load([ "1000", "Cash", "Asset", "", "1,234.56", "" ])
      expect(opening("1000")).to eq(usd(BigDecimal("1234.56")))
    end

    it "reads account types in any case" do
      load([ "1000", "Cash", "ASSETS", "", "1", "" ], [ "4000", "Sales", "revenue", "", "", "" ])
      expect([ account("1000").category, account("4000").category ]).to eq(%w[asset income])
    end

    {
      "a parent amount that differs from its children" => [ [ [ "1000", "Assets", "Asset", "", "200", "" ], [ "1100", "Current", "Asset", "", "250", "1000" ] ], /Amounts mismatch for account 1000/ ],
      "an unknown account type" => [ [ [ "1000", "Assets", "Stuff", "", "", "" ] ], /Unknown account type 'Stuff' for account 1000/ ],
      "a parent that is not in the file" => [ [ [ "1100", "Current", "Asset", "", "", "1000" ] ], /Parent 1000 for account 1100 is not in the file/ ],
      "a contra target that is not in the file" => [ [ [ "1025", "Allowance", "Asset", "1020", "", "" ] ], /Contra account 1020 for account 1025 is not in the file/ ],
      "a duplicate code" => [ [ [ "1000", "Cash", "Asset", "", "", "" ], [ "1000", "Bank", "Asset", "", "", "" ] ], /Account 1000 appears more than once/ ],
      "a starting balance that is not a number" => [ [ [ "1000", "Cash", "Asset", "", "lots", "" ] ], /Starting Balance "lots" for account 1000 is not a number/ ],
      "a row without a code" => [ [ [ "", "Cash", "Asset", "", "", "" ] ], /A row has no Account Code/ ]
    }.each do |problem, (rows, message)|
      it "rejects #{problem} and creates nothing" do
        expect { load(*rows) }.to raise_error(ArgumentError, message)
        expect(TudlaAccounting::Account.where(organization: organization).count).to eq(0)
      end
    end
  end

  it "needs a subclass to read the file" do
    expect { described_class.call(organization, "file", opening_date) }.to raise_error(NotImplementedError)
  end
end
