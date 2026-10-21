require "rails_helper"

RSpec.describe TudlaAccounting::BudgetGrid do
  let(:organization) { create(:organization, currency: "AUD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let(:budget) { TudlaAccounting::Budget.create!(organization: organization, period: year, name: "Original") }
  let(:grid) { described_class.new(budget.reload) }

  before do
    TudlaAccounting::AccountsCreator.call([
      { code: "4000", name: "Sales", category: "income", children: [ { code: "4010", name: "Products", category: "income" } ] },
      { code: "4900", name: "Sales returns", category: "income", contra_account: "4010" },
      { code: "6100", name: "Rent", category: "expense" }, { code: "6200", name: "Software", category: "expense" }, { code: "6300", name: "Old", category: "expense" }
    ], organization)
    account("6300").deactivate!
    budget.set_amounts!(account("4010").id => { month(1).id => 1_000_00, month(2).id => 1_000_00 }, account("4000").id => { month(1).id => 50_00 },
                        account("4900").id => { month(1).id => 100_00 }, account("6100").id => { month(1).id => 400_00 })
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def month(number) = year.children.order(:from_date).to_a[number - 1]

  # A file of rows written to a temporary path.
  def file(rows, extension: ".csv")
    file = Tempfile.new([ "budget", extension ])
    file.binmode
    file.write(extension == ".csv" ? CSV.generate { |csv| rows.each { |row| csv << row } } : TudlaAccounting::Reports::Table.new(rows).to_xlsx("Budget"))
    file.flush
    file.path
  end

  it "lays the accounts out in their tree, parents adding up, contra accounts deducted, inactive ones left out" do
    expect(grid.rows("income").map { |row| [ row.account.code, row.depth, row.kind ] }).to eq([ [ "4000", 0, :parent ], [ "4000", 1, :own ], [ "4010", 1, :account ], [ "4900", 0, :account ] ])
    expect(grid.rows("expense").map { |row| row.account.code }).to eq(%w[6100 6200])
    expect(grid.total(account("4000"), month(1))).to eq(1_050_00)
    expect(grid.total(account("4000"))).to eq(2_050_00)
    expect(grid.section_total("income", month(1))).to eq(950_00)
    expect(grid.net_profit).to eq(1_550_00)
  end

  it "downloads as a table with a row for each account taking amounts" do
    rows = grid.to_table.rows
    expect(rows.first).to eq([ "Section", "Code", "Account", *year.children.order(:from_date).map(&:label), "Total" ])
    expect(rows.map { |row| row[0..3] }).to eq([
      [ "Section", "Code", "Account", "Jan 2026" ],
      [ "Income", "4000", "Sales (own)", Money.new(50_00, "AUD") ], [ "Income", "4010", "Products", Money.new(1_000_00, "AUD") ], [ "Income", "4900", "Sales returns", Money.new(100_00, "AUD") ],
      [ "Income", nil, "Total income", Money.new(950_00, "AUD") ],
      [ "Expenses", "6100", "Rent", Money.new(400_00, "AUD") ], [ "Expenses", "6200", "Software", nil ], [ "Expenses", nil, "Total expenses", Money.new(400_00, "AUD") ],
      [ nil, nil, "Net profit (loss)", Money.new(550_00, "AUD") ]
    ])
    expect(rows[2].last).to eq(Money.new(2_000_00, "AUD"))
  end

  describe "#read" do
    it "reads a downloaded budget back, as CSV and as Excel" do
      expect(grid.read(file(CSV.parse(grid.to_table.to_csv)), ".csv")).to include(account("4010").id => hash_including(month(1).id => 1_000_00, month(3).id => 0))
      expect(grid.read(file(grid.to_table.rows, extension: ".xlsx"), ".xlsx")).to include(account("6100").id => hash_including(month(1).id => 400_00))
    end

    it "matches months by headings of several kinds, and codes Excel made numbers" do
      read = grid.read(file([ [ "code", "Mar-26", "2026-04", Date.new(2026, 5, 1), "Note" ], [ 6200.0, "1,250.50", 30, "" ], [ "", "1", "1" ] ]), ".csv")
      expect(read).to eq(account("6200").id => { month(3).id => 1_250_50, month(4).id => 30_00, month(5).id => 0 })
      expect(grid.read(file([ [ "Code", Date.new(2026, 5, 1) ], [ "6200", 12.5 ] ], extension: ".xlsx"), ".xlsx")).to eq(account("6200").id => { month(5).id => 12_50 })
    end

    it "says what it can't read" do
      expect { grid.read(file([ [ "Account", "Jan 2026" ] ]), ".csv") }.to raise_error(ArgumentError, "The file has no Code column")
      expect { grid.read(file([ [ "Code", "Jan 2025" ] ]), ".csv") }.to raise_error(ArgumentError, "The file has no columns for the months of 2026")
      expect { grid.read(file([ [ "Code", "Jan 2026" ], [ "9999", "1" ], [ "6100", "lots" ], [ "6200", "1" ], [ "6200", "2" ] ]), ".csv") }
        .to raise_error(ArgumentError, "Row 2: no income or expense account has the code 9999; Row 3, Jan 2026: lots isn't an amount; Row 5: 6200 is in the file twice")
      expect { grid.read(file([ [ "Code" ] ]), ".ods") }.to raise_error(ArgumentError, "Upload a .csv or .xlsx file")
      expect { grid.read(file([ [ "Code" ] ]), ".xlsx") }.to raise_error(ArgumentError, /\AThe file can't be read: /)
      bad = Tempfile.new([ "budget", ".csv" ]).tap { |f| f.binmode.write("Code,Jan 2026\n6100,\xFF\n".b).tap { f.flush } }
      expect { grid.read(bad.path, ".csv") }.to raise_error(ArgumentError, /\AThe file can't be read: /)
    end
  end
end
