require "rails_helper"
require_relative "../../support/configuration"

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

  describe "#for_organization" do
    include_context "with isolated TudlaAccounting configuration"

    let(:organization) { Struct.new(:id, :name, :currency).new(7, "Acme", "AUD") }
    let(:values) do
      { organization_label: "Acme Pty Ltd", cash_account_codes: %w[1010], number_format: :comma, country: "AU", document_header: "Acme\n1 Demo Street",
        books_header: "ACME", withholding_agent: { tin: "1" }, tax_registration: TudlaAccounting::TaxRegistration.australia("51 824 753 556"),
        document_mail_from: "accounts@acme.test", document_mail_reply_to: "help@acme.test" }
    end

    it "reads every per-organization setting the same whether given a value or a callable" do
      expect(values.keys).to match_array(described_class::PER_ORGANIZATION)
      read = lambda do
        [ TudlaAccounting.organization_label(organization), config.cash_account_codes_for(organization), config.number_format_for(organization), config.country_for(organization),
          config.document_header_for(organization), config.books_header_for(organization), config.withholding_agent_for(organization)[:tin],
          config.tax_registration_for(organization), config.document_mail_address(:document_mail_from, organization), config.document_mail_address(:document_mail_reply_to, organization) ]
      end
      TudlaAccounting.configuration = config
      values.each { |setting, value| config.public_send(:"#{setting}=", value) }
      as_values = read.call
      values.each { |setting, value| config.public_send(:"#{setting}=", ->(org) { value if org.name == "Acme" }) }
      expect(read.call).to eq(as_values)
      expect(as_values).to eq([ "Acme Pty Ltd", %w[1010], :comma, "AU", "Acme\n1 Demo Street", "ACME", "1", values[:tax_registration], "accounts@acme.test", "help@acme.test" ])
    end

    it "refuses a setting that isn't per organization" do
      expect { config.for_organization(:rounding, organization) }.to raise_error(ArgumentError, /rounding isn't a per-organization setting/)
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

  describe "#books_header_for" do
    it "heads the books of accounts with the document header unless set otherwise" do
      organization = Struct.new(:id, :name).new(7, "Acme")
      expect(config.books_header_for(organization)).to eq("Acme")
      config.document_header = ->(org) { "#{org.name}\n1 Demo Street" }
      expect(config.books_header_for(organization)).to eq("Acme\n1 Demo Street")
      config.books_header = ->(org) { "#{org.name.upcase}\nTIN: 000-000-000-000" }
      expect(config.books_header_for(organization)).to eq("ACME\nTIN: 000-000-000-000")
    end
  end

  describe "#country?" do
    let(:organization) { Struct.new(:id, :name).new(7, "Acme") }

    it "shows every country's reports without a country, and only that country's with one" do
      expect(config.country_for(organization)).to be_nil
      expect(config.country?(organization, "PH")).to be(true)
      config.country = "au"
      expect(config.country_for(organization)).to eq("AU")
      expect([ config.country?(organization, :au), config.country?(organization, "PH") ]).to eq([ true, false ])
      config.country = ->(org) { "PH" if org.name == "Acme" }
      expect([ config.country?(organization, "AU"), config.country?(organization, "PH") ]).to eq([ false, true ])
      config.country = ->(_org) { "" }
      expect(config.country?(organization, "AU")).to be(true)
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
