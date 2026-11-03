require "rails_helper"

RSpec.describe TudlaAccounting::WithholdingCode do
  let(:organization) { create(:organization, currency: "PHP") }

  before do
    TudlaAccounting::AccountsCreator.call([
      { code: "1200", name: "Creditable tax", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" },
      { code: "2300", name: "Withholding payable", category: "liability" }, { code: "2100", name: "Payables", category: "liability", role: "payable" },
      { code: "2400", name: "Taxes", category: "liability", children: [ { code: "2410", name: "VAT", category: "liability" } ] }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def build(**attributes) = described_class.new({ organization: organization, code: "wc010", name: " Professionals  ", rate: "0.1", payable_account: account("2300") }.merge(attributes))

  it "has a code, a rate as a percentage, and either account" do
    code = build(creditable_account: account("1200")).tap(&:save!)
    expect(code).to have_attributes(code: "WC010", name: "Professionals", label: "WC010 (10%)", rate_percent: "10")
    expect(build(code: "WI010", payable_account: nil, creditable_account: account("1200"))).to be_valid
    expect(described_class.active).to eq([ code ])
    code.rate_percent = "12.5"
    expect(code.rate).to eq(BigDecimal("0.125"))
    expect(build.tap(&:valid?).errors[:code]).to eq([ "has already been taken" ])
  end

  it "reads a rate in the organization's number format, and says when it can't" do
    code = build(rate: nil)
    code.rate_percent = "abc"
    expect(code).not_to be_valid
    expect(code.errors[:rate]).to include("abc isn't a number")
  end

  it "has a rate between 0 and 100%, which the database holds it to" do
    [ 0, 1, -0.1 ].each { |rate| expect(build(rate: rate)).not_to be_valid }
    code = build.tap(&:save!)
    expect { code.update_columns(rate: 0) }.to raise_error(ActiveRecord::StatementInvalid, /tudla_accounting_withholding_codes_rate_range/)
  end

  it "needs an account, which the database holds it to" do
    expect(build(payable_account: nil).tap(&:valid?).errors[:base]).to eq([ "Choose an account for tax withheld from suppliers, for tax customers withhold, or both" ])
    code = build.tap(&:save!)
    expect { code.update_columns(payable_account_id: nil) }.to raise_error(ActiveRecord::StatementInvalid, /tudla_accounting_withholding_codes_account_given/)
  end

  it "takes only a postable liability for tax withheld from suppliers, and a postable asset for tax customers withhold" do
    errors = ->(**attributes) { build(**attributes).tap(&:valid?).errors }
    expect(errors.call(payable_account: account("1200"))[:payable_account]).to eq([ "must be a liability account" ])
    expect(errors.call(creditable_account: account("2300"))[:creditable_account]).to eq([ "must be an asset account" ])
    expect(errors.call(payable_account: account("2100"))[:payable_account]).to eq([ "can't be the receivables or payables account" ])
    expect(errors.call(payable_account: account("2100-PHP"))[:payable_account]).to eq([ "can't be the receivables or payables account" ])
    expect(errors.call(creditable_account: account("1100-PHP"))[:creditable_account]).to eq([ "can't be the receivables or payables account" ])
    expect(errors.call(payable_account: account("2400"))[:payable_account].sole).to include("sub-accounts")
    other = create(:organization, currency: "PHP")
    TudlaAccounting::AccountsCreator.call([ { code: "2300", name: "Theirs", category: "liability" } ], other)
    expect(errors.call(payable_account: TudlaAccounting::Account.find_by!(organization: other))[:payable_account]).to eq([ "must belong to the same organization" ])
    account("2410").update!(active: false)
    expect(errors.call(payable_account: account("2410"))[:payable_account]).to eq([ "is inactive" ])
  end

  it "keeps an account that later went inactive" do
    code = build(payable_account: account("2410")).tap(&:save!)
    account("2410").update!(active: false)
    expect(code.reload.update(name: "Renamed")).to be(true)
  end

  it "can't be deleted while a contact has it as the default" do
    code = build.tap(&:save!)
    contact = TudlaAccounting::Contact.create!(organization: organization, name: "Ledger & Co", kind: "supplier", default_withholding_code: code)
    expect(code).to be_used
    expect(code.destroy).to be(false)
    expect(code.errors.full_messages).to eq([ "Contacts use WC010 as their default; change them first" ])
    contact.update!(default_withholding_code: nil)
    expect(code.destroy).to be_truthy
  end
end
