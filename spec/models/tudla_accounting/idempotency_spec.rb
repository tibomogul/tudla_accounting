require "rails_helper"
require_relative "../../support/entry_sources"

RSpec.describe "Idempotent entry creation" do
  let(:organization) { create(:organization) }

  before do
    create(:tudla_accounting_account, code: "1100", category: :asset, organization: organization)
    create(:tudla_accounting_account, code: "4000", category: :income, organization: organization)
  end

  def entry_hash(org = organization, **overrides)
    { organization_type: "Organization", organization_id: org.id, particulars: "Invoice 7", transacted_at: "2026-03-10T09:00:00Z",
      details: [ { account_code: "1100", amount: "USD 100.00" }, { account_code: "4000", amount: "USD 100.00" } ] }.merge(overrides)
  end

  it "returns the entry already created with the same key, instead of a second one" do
    first = TudlaAccounting::Entry.create_from_ruby_hash(entry_hash(idempotency_key: "webhook-41"))
    again = nil
    expect { again = TudlaAccounting::Entry.create_from_ruby_hash(entry_hash(idempotency_key: "webhook-41", particulars: "Changed")) }
      .not_to change(TudlaAccounting::Entry, :count)
    expect(again).to eq(first)
    expect(first.reload.idempotency_key).to eq("webhook-41")
  end

  it "keeps keys apart per organization, and creates every entry without one" do
    other = create(:organization)
    create(:tudla_accounting_account, code: "1100", category: :asset, organization: other)
    create(:tudla_accounting_account, code: "4000", category: :income, organization: other)

    expect { TudlaAccounting::Entry.create_from_ruby_hash(entry_hash(idempotency_key: "k")) }.to change(TudlaAccounting::Entry, :count).by(1)
    expect { TudlaAccounting::Entry.create_from_ruby_hash(entry_hash(other, idempotency_key: "k")) }.to change(TudlaAccounting::Entry, :count).by(1)
    expect { 2.times { TudlaAccounting::Entry.create_from_ruby_hash(entry_hash) } }.to change(TudlaAccounting::Entry, :count).by(2)
  end

  it "returns the entry another process created with the key at the same moment" do
    theirs = TudlaAccounting::Entry.create_from_ruby_hash(entry_hash(idempotency_key: "race"))
    looked = false # it wasn't there when we first looked
    allow(TudlaAccounting::Entry).to receive(:find_by).and_wrap_original do |original, *args, **options|
      looked ? original.call(*args, **options) : (looked = true) && nil
    end

    expect(TudlaAccounting::Entry.create_from_ruby_hash(entry_hash(idempotency_key: "race"))).to eq(theirs)
  end

  it "still raises for other uniqueness problems" do
    allow(TudlaAccounting::Entry).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)
    expect { TudlaAccounting::Entry.create_from_ruby_hash(entry_hash) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  describe "entries from host-app records" do
    include_context "with entry source models"

    let(:invoice) { Invoice.create! }

    it "makes one entry per record unless the callable chooses its own key, or none" do
      TudlaAccounting.register_entry_source("Invoice", ->(record) { entry_hash(particulars: "Invoice #{record.id}") })
      first = TudlaAccounting.create_entry_from_source!(invoice)
      expect(first.idempotency_key).to eq("Invoice:#{invoice.id}")
      expect(TudlaAccounting.create_entry_from_source!(invoice)).to eq(first)

      TudlaAccounting.register_entry_source("Invoice", ->(_record) { entry_hash(idempotency_key: nil) })
      expect { 2.times { TudlaAccounting.create_entry_from_source!(invoice) } }.to change(TudlaAccounting::Entry, :count).by(2)
    end
  end
end
