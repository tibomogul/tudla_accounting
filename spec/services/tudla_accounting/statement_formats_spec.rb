require "rails_helper"

RSpec.describe "Importing OFX and CAMT.053 statements" do
  let(:organization) { create(:organization, currency: "AUD") }

  before do
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1001", name: "Bank, EUR", category: "asset", currency: "EUR" },
      { code: "2400", name: "Credit card", category: "liability" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def import(path, into: account("1000")) = TudlaAccounting::BankStatementImporter.call(into, path)
  def lines(code = "1000") = TudlaAccounting::BankStatementLine.where(account: account(code)).order(:occurred_on, :id)
  def read(code = "1000") = lines(code).map { |line| line.slice(:occurred_on, :description, :reference, :amount_cents, :balance_cents, :external_id).symbolize_keys }

  # A fixture's text changed, written to a file to import.
  def variant(name, binary: false)
    text = binary ? File.binread(file_fixture(name)) : File.read(file_fixture(name))
    file = Tempfile.new([ "statement", File.extname(name) ])
    file.binmode
    file.write(yield(text))
    file.flush
    file.path
  end

  describe "OFX 1.x (SGML)" do
    it "reads each transaction by its FITID, the closing balance on the last, and skips what it has" do
      expect(import(file_fixture("statement_ofx1.ofx"))).to eq(imported: 3, skipped: 0, format: :ofx)
      expect(read).to eq([
        { occurred_on: Date.new(2026, 3, 2), description: "Café Supplies Pty - Invoice 1001", reference: nil, amount_cents: 1_500_00, balance_cents: nil, external_id: "id:2026030201" },
        { occurred_on: Date.new(2026, 3, 10), description: "Rent & outgoings", reference: "000123", amount_cents: -240_50, balance_cents: nil, external_id: "id:2026031001" },
        { occurred_on: Date.new(2026, 3, 31), description: "Account fee", reference: nil, amount_cents: -12_00, balance_cents: 2_247_50, external_id: "id:2026033101" }
      ])
      expect(import(file_fixture("statement_ofx1.ofx"))).to eq(imported: 0, skipped: 3, format: :ofx)
    end

    it "refuses a statement in another currency, for several accounts, or that can't be read" do
      expect { import(file_fixture("statement_ofx1.ofx"), into: account("1001")) }.to raise_error(ArgumentError, "The statement is in AUD; the account is held in EUR")

      two = variant("statement_ofx1.ofx", binary: true) { |text| text.sub("</STMTTRNRS>", "</STMTTRNRS><STMTTRNRS><STMTRS><CURDEF>AUD<BANKACCTFROM><ACCTID>999</BANKACCTFROM></STMTRS></STMTTRNRS>") }
      expect { import(two) }.to raise_error(ArgumentError, "The OFX file holds statements for 2 accounts; import one account's at a time")
      expect { import(variant("statement_ofx1.ofx", binary: true) { |text| text.gsub(/<\/?STMTRS>/, "") }) }.to raise_error(ArgumentError, "The OFX file holds no statement")
      expect { import(variant("statement_ofx1.ofx", binary: true) { |text| text.sub("<FITID>2026030201", "") }) }.to raise_error(ArgumentError, "A transaction has no FITID")
      expect { import(variant("statement_ofx1.ofx", binary: true) { |text| text.sub("<TRNAMT>-12.00", "<TRNAMT>lots") }) }
        .to raise_error(ArgumentError, "2026033101 has an amount that can't be read: lots")
      expect { import(variant("statement_ofx1.ofx", binary: true) { |text| text.sub("<TRNAMT>-12.00", "<TRNAMT>0.00") }) }.to raise_error(ArgumentError, "Transaction 2026033101 has no amount")
      expect { import(variant("statement_ofx1.ofx", binary: true) { |text| text.sub("<DTPOSTED>20260310", "<DTPOSTED>soon") }) }
        .to raise_error(ArgumentError, "2026031001 has a date that can't be read: soon")
      expect { import(variant("statement_ofx1.ofx", binary: true) { |text| text.gsub(%r{<STMTTRN>.*?</STMTTRN>}m, "") }) }.to raise_error(ArgumentError, "The statement has no transactions")
      expect(lines).to be_empty
    end
  end

  it "reads OFX 2.x (XML), a credit card's, with a decimal comma" do
    expect(import(file_fixture("statement_ofx2.qfx"), into: account("2400"))).to eq(imported: 1, skipped: 0, format: :ofx)
    expect(read("2400")).to eq([ { occurred_on: Date.new(2026, 3, 5), description: "Software Co", reference: "R-77", amount_cents: -49_95, balance_cents: -49_95, external_id: "id:CC-0001" } ])
  end

  describe "CAMT.053" do
    it "reads booked entries, leaving pending ones out, with the closing balance on the last" do
      expect(import(file_fixture("statement_camt053.xml"), into: account("1001"))).to eq(imported: 2, skipped: 0, format: :camt053)
      unreferenced = read("1001").last[:external_id]
      expect(read("1001")).to eq([
        { occurred_on: Date.new(2026, 3, 3), description: "Invoice 17 March services", reference: "INV-2026-17", amount_cents: 1_200_00, balance_cents: nil, external_id: "id:BANKREF-1" },
        { occurred_on: Date.new(2026, 3, 20), description: "Stadtwerke", reference: nil, amount_cents: -284_50, balance_cents: 1_015_50, external_id: unreferenced }
      ])
      expect(unreferenced).to match(/\Acamt:\h{32}\z/)
      expect(import(file_fixture("statement_camt053.xml"), into: account("1001"))).to eq(imported: 0, skipped: 2, format: :camt053)
    end

    it "refuses a statement in another currency, for several accounts, or that isn't XML" do
      expect { import(file_fixture("statement_camt053.xml")) }.to raise_error(ArgumentError, "The statement is in EUR; the account is held in AUD")
      two = variant("statement_camt053.xml") { |text| text.sub("</Stmt>", "</Stmt><Stmt><Acct><Id><IBAN>GB29NWBK60161331926819</IBAN></Id></Acct></Stmt>") }
      expect { import(two, into: account("1001")) }.to raise_error(ArgumentError, "The CAMT file holds statements for 2 accounts; import one account's at a time")
      expect { import(variant("statement_camt053.xml") { |text| text.sub("</Document>", "") }, into: account("1001")) }
        .to raise_error(ArgumentError, /\AThe file isn't XML that can be read/)
      expect { import(variant("statement_camt053.xml") { |text| text.gsub(%r{<Stmt>.*</Stmt>}m, "") }, into: account("1001")) }
        .to raise_error(ArgumentError, "The CAMT file holds no statement")
      expect { import(variant("statement_camt053.xml") { |text| text.sub("<Dt>2026-03-20</Dt>", "<Dt>someday</Dt>") }, into: account("1001")) }
        .to raise_error(ArgumentError, "The statement has a date that can't be read: someday")
      expect { import(variant("statement_camt053.xml") { |text| text.sub(%r{<Amt Ccy="EUR">284.50</Amt>}, "") }, into: account("1001")) }
        .to raise_error(ArgumentError, "An entry has no amount")
      expect { import(variant("statement_camt053.xml") { |text| text.sub(">284.50<", ">lots<") }, into: account("1001")) }
        .to raise_error(ArgumentError, "The statement has an amount that can't be read: lots")
      expect(lines("1001")).to be_empty
    end

    it "takes a debit closing balance, other parties' names and the entry's own information" do
      text = variant("statement_camt053.xml") do |xml|
        xml.sub("<CdtDbtInd>CRDT</CdtDbtInd><Dt><Dt>2026-03-31", "<CdtDbtInd>DBIT</CdtDbtInd><Dt><Dt>2026-03-31")
           .sub(%r{<RmtInf>.*?</RmtInf>}m, "").sub("<Sts><Cd>BOOK</Cd></Sts>\n        <BookgDt><Dt>2026-03-20", "<Sts>BOOK</Sts>\n        <BookgDt><Dt>2026-03-20")
           .sub(%r{<NtryDtls><TxDtls>\s*<Refs><EndToEndId>NOTPROVIDED.*?</NtryDtls>}m, "<AddtlNtryInf>Direct debit</AddtlNtryInf>")
      end
      import(text, into: account("1001"))
      expect(read("1001").map { |line| line.values_at(:description, :balance_cents) }).to eq([ [ "Globex GmbH", nil ], [ "Direct debit", -1_015_50 ] ])
    end
  end
end
