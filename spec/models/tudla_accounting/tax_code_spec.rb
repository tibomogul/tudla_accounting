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
end
