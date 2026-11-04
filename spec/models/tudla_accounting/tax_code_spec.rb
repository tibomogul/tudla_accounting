require "rails_helper"

RSpec.describe TudlaAccounting::TaxCode do
  let(:organization) { create(:organization, currency: "PHP") }

  it "is taxed at its rate unless marked zero-rated or exempt, which the database holds to a rate of 0" do
    vat = described_class.create!(organization: organization, code: "VAT0", name: "VAT", rate: 0, kind: :sales)
    exports = described_class.create!(organization: organization, code: "ZR", name: "Zero-rated", rate: 0, kind: :sales, treatment: :zero_rated)
    expect([ vat, exports ].map(&:treatment)).to eq(%w[standard zero_rated])
    expect(described_class.exempt).to be_empty

    expect { exports.update_columns(rate: BigDecimal("0.12")) }.to raise_error(ActiveRecord::StatementInvalid, /tudla_accounting_tax_codes_untaxed_without_rate/)
  end

  it "says what a taxed purchases code's lines are bought as, and only such a code" do
    account = create(:tudla_accounting_account, code: "1500", category: :asset, organization: organization)
    input = described_class.create!(organization: organization, code: "IN", name: "Input", rate: "0.12", kind: :purchases, account: account)
    expect(input.purchase_type).to be_nil
    input.update!(purchase_type: :capital_goods)
    expect(input).to be_bought_as_capital_goods
    expect(described_class.new(organization: organization, code: "X", name: "X", rate: "0.12", kind: :purchases, account: account, purchase_type: "rent")).not_to be_valid

    output = described_class.create!(organization: organization, code: "OUT", name: "Output", rate: "0.12", kind: :sales, account: account, purchase_type: :services)
    exempt = described_class.create!(organization: organization, code: "EX", name: "Exempt", rate: "0", kind: :purchases, treatment: :exempt, purchase_type: :services)
    expect([ output.purchase_type, exempt.purchase_type ]).to eq([ nil, nil ])
  end
end
