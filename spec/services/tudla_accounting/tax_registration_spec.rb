require "rails_helper"

RSpec.describe TudlaAccounting::TaxRegistration do
  describe ".abn?" do
    it "follows the Australian Business Register's worked example" do
      expect(described_class.abn?("51 824 753 556")).to be(true)
      expect(described_class.abn?("51824753556")).to be(true)
      expect(described_class.abn?("51-824-753-556")).to be(true)
    end

    it "refuses a wrong check digit, the wrong length and anything else" do
      expect(described_class.abn?("51 824 753 557")).to be(false)
      expect(described_class.abn?("12 345 678 901")).to be(false)
      expect(described_class.abn?("51 824 753 55")).to be(false)
      expect(described_class.abn?("DE123456789")).to be(false)
      expect(described_class.abn?(nil)).to be(false)
    end
  end

  it "has Australia's wording, and trims the number" do
    expect(described_class.australia(" 51 824 753 556 ")).to have_attributes(label: "ABN", number: "51 824 753 556", tax_name: "GST", invoice_title: "Tax invoice")
    expect(described_class.australia(" ").number).to be_nil
  end

  it "calls a contact's number an ABN only once it has passed the check" do
    registration = described_class.australia("51 824 753 556")
    expect(registration.contact_label("51 824 753 556")).to eq("ABN")
    expect(registration.contact_label("DE123456789")).to eq("Tax number")
    expect(registration.fails_check?("DE123456789")).to be(true)
    expect(registration.fails_check?(nil)).to be(false)
  end

  it "has nothing to fail without a check" do
    registration = described_class.new(label: "VAT reg no.", number: "123", tax_name: "VAT", invoice_title: "VAT invoice")
    expect(registration.fails_check?("anything")).to be(false)
    expect(registration.contact_label("anything")).to eq("Tax number")
    expect(described_class.new(label: "Reg").tax_name).to eq("Tax")
  end
end
