require "rails_helper"

RSpec.describe TudlaAccounting::Reports::SampleBooks, type: :service do
  let(:organization) { create(:organization, name: "Bayanihan Corp.", currency: "PHP") }
  let(:books) { described_class.new(organization, year: 2027) }

  it "gives every book one page of made-up rows, balanced, in the organization's currency, for the year" do
    expect(books).to be_sample
    expect(TudlaAccounting::Reports::BooksOfAccounts.new(organization, from: nil, thru: nil)).not_to be_sample
    expect(books.period_label).to eq("January 1 to December 31, 2027")
    expect(books.books.map(&:key)).to eq(TudlaAccounting::Reports::BooksOfAccounts::BOOKS.keys)
    expect(books.books.map { |book| book.pages.size }).to all(eq(1))
    expect(books.books.flat_map(&:pages).map(&:balanced)).to all(be(true))
    expect(books.books.flat_map(&:pages).flat_map(&:rows).flat_map { |row| row.cells.values }.grep(Money).map { |money| money.currency.iso_code }.uniq).to eq([ "PHP" ])
    expect(books.books.flat_map(&:pages).flat_map(&:rows).flat_map { |row| row.cells.values }.grep(Date).map(&:year).uniq).to eq([ 2027 ])
    expect(TudlaAccounting::Entry.where(organization: organization)).to be_empty
  end

  it "uses only the columns each book has, and its ledger adds up" do
    books.books.each { |book| expect(book.keys).to include(*book.pages.sole.rows.flat_map { |row| row.cells.keys }.uniq) }

    page = books.book("general_ledger").pages.sole
    expect(page.account).to have_attributes(name: "Cash in Bank", code: "1010")
    expect(page.rows.first.cells[:balance] + page.totals[:debit] - page.totals[:credit]).to eq(page.closing)
    expect(page.rows.last.cells[:balance]).to eq(page.closing)
  end

  it "writes whole amounts in a currency without decimals" do
    yen = described_class.new(create(:organization, name: "Yen KK", currency: "JPY"), year: 2027)
    expect(yen.book("sales").pages.sole.totals[:receivable]).to eq(Money.new(116_200, "JPY"))
  end
end
