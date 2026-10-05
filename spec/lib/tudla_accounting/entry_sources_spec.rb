require "rails_helper"
require_relative "../../support/entry_sources"

RSpec.describe "TudlaAccounting entry sources" do
  include_context "with isolated TudlaAccounting configuration"

  describe ".register_entry_source" do
    it "registers a callable by class name and returns the registry" do
      callable = ->(_record) { {} }
      expect(TudlaAccounting.register_entry_source("Invoice", callable)).to eq("Invoice" => callable)
    end

    it "requires a class name string, so registrations survive code reloading" do
      expect { TudlaAccounting.register_entry_source(Object, ->(_record) { {} }) }
        .to raise_error(ArgumentError, "source_type must be a String")
    end

    it "requires something callable" do
      expect { TudlaAccounting.register_entry_source("Invoice", "not callable") }
        .to raise_error(ArgumentError, "callable must respond to call")
    end
  end

  describe ".create_entry_from_source!" do
    include_context "with entry source models"

    let(:organization) { create(:organization) }
    let!(:receivable) { create(:tudla_accounting_account, code: "1100", category: :asset, organization: organization) }
    let!(:sales) { create(:tudla_accounting_account, code: "4000", category: :income, organization: organization) }
    let(:invoice) { Invoice.create!(due_date: Time.zone.local(2026, 4, 30)) }

    def invoice_hash(invoice, **overrides)
      {
        organization_type: "Organization", organization_id: organization.id,
        particulars: "Invoice ##{invoice.id}", transacted_at: "2026-03-10T09:00:00Z",
        details: [ { account_code: "1100", amount: "USD 1100.00" }, { account_code: "4000", amount: "USD 1100.00" } ]
      }.merge(overrides)
    end

    it "creates an unposted entry linked back to the record" do
      TudlaAccounting.register_entry_source("Invoice", ->(record) { invoice_hash(record) })

      entry = TudlaAccounting.create_entry_from_source!(invoice)

      expect(entry).to be_persisted
      expect(entry).to have_attributes(source: invoice, particulars: "Invoice ##{invoice.id}", posted_at: nil)
      expect(entry.details.map(&:account)).to contain_exactly(receivable, sales)
    end

    it "lets the callable set source_type and source_id itself" do
      TudlaAccounting.register_entry_source("Invoice", ->(record) { invoice_hash(record, source_type: "Bill", source_id: 99) })
      expect(TudlaAccounting.create_entry_from_source!(invoice)).to have_attributes(source_type: "Bill", source_id: 99)
    end

    it "returns nil without creating anything when the callable returns nil" do
      TudlaAccounting.register_entry_source("Invoice", ->(_record) { nil })
      expect { expect(TudlaAccounting.create_entry_from_source!(invoice)).to be_nil }.not_to change(TudlaAccounting::Entry, :count)
    end

    it "raises for a record whose class is not registered" do
      expect { TudlaAccounting.create_entry_from_source!(invoice) }.to raise_error(ArgumentError, "No source registered for Invoice")
    end

    it "opens a receivable once the entry is posted" do
      TudlaAccounting::PeriodCreator.call(organization, 2026)
      TudlaAccounting.register_entry_source("Invoice", ->(record) { invoice_hash(record) })

      TudlaAccounting.create_entry_from_source!(invoice).post(Time.zone.local(2026, 3, 10, 9))

      expect(TudlaAccounting::CarryingAmount.last).to have_attributes(carrying_amount_type: "receivable", amount_cents: 1100_00,
                                                                      due_date: invoice.due_date)
    end
  end
end
