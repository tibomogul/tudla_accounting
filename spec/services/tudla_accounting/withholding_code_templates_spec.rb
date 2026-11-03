require "rails_helper"

RSpec.describe TudlaAccounting::WithholdingCodeTemplates do
  let(:organization) { create(:organization, currency: "PHP") }

  before do
    TudlaAccounting::AccountsCreator.call([ { code: "1200", name: "Creditable tax", category: "asset" }, { code: "2300", name: "Withholding payable", category: "liability" } ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def codes = TudlaAccounting::WithholdingCode.where(organization: organization)

  it "offers the Philippine list" do
    expect(described_class.choices).to eq([ [ "Philippines: expanded withholding tax, common payments (BIR Form 1601-EQ, January 2019)", "ph_expanded" ] ])
  end

  it "adds the 20 codes with the published rates and the accounts given" do
    expect(described_class.add!(organization, "ph_expanded", payable_account: account("2300"), creditable_account: account("1200"))).to eq(20)
    expect(codes.order(:code).to_h { |code| [ code.code, code.rate_percent ] }).to eq(
      "WC010" => "10", "WC011" => "15", "WC050" => "10", "WC051" => "15", "WC060" => "10", "WC061" => "15", "WC100" => "5", "WC120" => "2", "WC158" => "1", "WC160" => "2",
      "WI010" => "5", "WI011" => "10", "WI050" => "5", "WI051" => "10", "WI060" => "5", "WI061" => "10", "WI100" => "5", "WI120" => "2", "WI158" => "1", "WI160" => "2"
    )
    expect(codes.find_by!(code: "WI011").name).to eq("Professionals (individual), income over ₱3M or VAT-registered")
    expect(codes.find_by!(code: "WC010").name).to eq("Professionals (corporate), income up to ₱720,000")
    expect(codes.find_by!(code: "WC158").name).to eq("Top withholding agents: goods (corporate)")
    expect(codes.pluck(:payable_account_id, :creditable_account_id).uniq).to eq([ [ account("2300").id, account("1200").id ] ])
  end

  it "keeps the codes the organization has, adding only the others" do
    mine = TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WC010", name: "Mine", rate: "0.2", payable_account: account("2300"))
    expect(described_class.add!(organization, "ph_expanded", creditable_account: account("1200"))).to eq(19)
    expect(mine.reload).to have_attributes(name: "Mine", rate: BigDecimal("0.2"))
    expect(described_class.add!(organization, "ph_expanded", creditable_account: account("1200"))).to eq(0)
  end

  it "adds none without an account, or from a list it doesn't know" do
    expect { described_class.add!(organization, "ph_expanded") }.to raise_error(ArgumentError, /Choose an account/)
    expect(codes).to be_empty
    expect { described_class.add!(organization, "nonsense", payable_account: account("2300")) }.to raise_error(ArgumentError, /Unknown withholding code template "nonsense"; expected one of ph_expanded/)
  end
end
