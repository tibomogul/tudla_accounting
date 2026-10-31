require "rails_helper"

RSpec.describe TudlaAccounting::Configuration do
  subject(:config) { described_class.new }

  it "leaves carrying amounts unconfigured by default" do
    expect(config).to have_attributes(carrying_amount_sources: {}, due_date_method: :due_date)
  end

  # Replaced by account roles: a host app's initializer still setting one says what to do.
  it "explains the removed account code settings" do
    expect { config.receivable_account_code = "1100" }
      .to raise_error(TudlaAccounting::ConfigurationError, /receivable_account_code was removed: mark the organization's account with role "receivable"/)
    expect { config.retained_earnings_account_code }.to raise_error(TudlaAccounting::ConfigurationError, /role "retained_earnings"/)
  end

  describe "#carrying_amount_sources=" do
    it "normalizes class names to strings and roles to symbols" do
      config.carrying_amount_sources = { SalesInvoice: "receivable", "VendorPayment" => :disbursement }
      expect(config.carrying_amount_sources).to eq("SalesInvoice" => :receivable, "VendorPayment" => :disbursement)
    end

    it "rejects unknown roles" do
      expect { config.carrying_amount_sources = { "Invoice" => :recievable } }
        .to raise_error(ArgumentError, /unknown carrying amount role :recievable for Invoice/)
    end
  end

  describe "#number_format" do
    it "is a style, a callable giving one for the organization, or nil for its currency's marks" do
      expect(config.number_format_for(:any)).to be_nil
      config.number_format = "comma"
      expect(config.number_format_for(:any)).to eq(:comma)
      config.number_format = ->(org) { org == :acme ? "point" : nil }
      expect([ config.number_format_for(:acme), config.number_format_for(:other) ]).to eq([ :point, nil ])
    end

    it "refuses any other" do
      expect { config.number_format = :space }.to raise_error(ArgumentError, "number_format must be :point, :comma, nil or a callable given the organization")
      config.number_format = ->(_org) { :space }
      config.organization_label = ->(org) { org.to_s.capitalize }
      expect { config.number_format_for(:acme) }.to raise_error(ArgumentError, "number_format gave :space for Acme; expected :point, :comma or nil")
    end
  end

  describe "#cash_account_codes_for" do
    it "gives the list, or what a callable returns for the organization" do
      config.cash_account_codes = "1010"
      expect(config.cash_account_codes_for(:any)).to eq(%w[1010])
      config.cash_account_codes = ->(org) { org == :acme ? %w[1010 1020] : nil }
      expect(config.cash_account_codes_for(:acme)).to eq(%w[1010 1020])
      expect(config.cash_account_codes_for(:other)).to eq([])
    end

    it "gives the codes as strings, leaving out blanks" do
      config.cash_account_codes = ->(_org) { [ 1010, "", nil, "1020" ] }
      expect(config.cash_account_codes_for(:any)).to eq(%w[1010 1020])
    end

    it "needs the organization" do
      expect { config.cash_account_codes_for(nil) }.to raise_error(ArgumentError, "an organization is required")
    end
  end

  describe "#organization_label" do
    it "names an organization by its class and id, unless set otherwise" do
      organization = Struct.new(:id, :name).new(7, "Acme")
      expect(config.organization_label.call(organization)).to eq("#{organization.class.name} 7")
      config.organization_label = ->(org) { org.name }
      expect(config.organization_label.call(organization)).to eq("Acme")
    end
  end

  describe "#dup" do
    it "copies the entry source registry, so the copy can change without affecting the original" do
      config.entry_sources["Invoice"] = ->(_record) { {} }
      copy = config.dup
      copy.entry_sources["Bill"] = ->(_record) { {} }

      expect(config.entry_sources.keys).to eq([ "Invoice" ])
      expect(copy.entry_sources.keys).to eq([ "Invoice", "Bill" ])
    end
  end
end
