require "rails_helper"

RSpec.describe "Database integrity" do
  let(:organization) { create(:organization, currency: "USD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let(:cash) { create(:tudla_accounting_account, code: "1000", category: :asset, organization: organization) }
  let(:capital) { create(:tudla_accounting_account, code: "3000", category: :equity, organization: organization) }

  def entry(posted: true)
    record = build(:tudla_accounting_entry, organization: organization, particulars: "Capital", transacted_at: Time.zone.local(2026, 2, 1))
    record.details.build(account: cash, tally: :debit, amount_cents: 100_00, currency: "USD")
    record.details.build(account: capital, tally: :credit, amount_cents: 100_00, currency: "USD")
    record.save!
    record.post(record.transacted_at) if posted
    record
  end

  # Each violation in its own savepoint, so the test's transaction carries on.
  def rejected(error = ActiveRecord::StatementInvalid, message = nil, &block)
    expect { ActiveRecord::Base.transaction(requires_new: true, &block) }.to raise_error(error, message)
  end

  describe "unique keys" do
    it "allows one balance per account and period" do
      TudlaAccounting::Balance.get(cash, year)
      rejected(ActiveRecord::RecordNotUnique) do
        TudlaAccounting::Balance.create!(account: cash, period: year, organization: organization, currency: "USD",
                                         starting_amount_cents: 0, current_amount_cents: 0, ending_amount_cents: 0)
      end
    end

    it "allows an account code once per organization" do
      cash
      rejected(ActiveRecord::RecordNotUnique) { build(:tudla_accounting_account, code: "1000", organization: organization).save(validate: false) }
      expect(build(:tudla_accounting_account, code: "1000", organization: create(:organization)).save).to be(true)
    end

    it "allows one receivable per line and one cached rate per currency pair and day" do
      line = entry.details.first
      create(:tudla_accounting_carrying_amount, detail: line)
      rejected(ActiveRecord::RecordNotUnique) { create(:tudla_accounting_carrying_amount, detail: line) }

      TudlaAccounting::ForexRate.create!(from: "EUR", to: "USD", year: 2026, month: 3, day: 31, rate: 1.1)
      rejected(ActiveRecord::RecordNotUnique) { TudlaAccounting::ForexRate.create!(from: "EUR", to: "USD", year: 2026, month: 3, day: 31, rate: 1.2) }
    end
  end

  describe "checks" do
    it "refuses a line of zero, or an unknown side or category, even skipping validations" do
      line = entry(posted: false).details.first
      rejected(ActiveRecord::StatementInvalid, /amount_positive/) { line.update_columns(amount_cents: 0) }
      rejected(ActiveRecord::StatementInvalid, /tally_known/) { line.update_columns(tally: 7) }
      rejected(ActiveRecord::StatementInvalid, /category_known/) { cash.update_columns(category: 9) }
    end
  end

  describe "posted entries" do
    it "can't be changed or deleted, nor their lines, even with raw SQL" do
      posted = entry
      line = posted.details.first

      rejected(ActiveRecord::StatementInvalid, /A posted entry \(id #{posted.id}\) cannot be changed; reverse it instead/) { posted.update_columns(particulars: "Edited") }
      rejected(ActiveRecord::StatementInvalid, /cannot be deleted/) { TudlaAccounting::Entry.where(id: posted.id).delete_all }
      rejected(ActiveRecord::StatementInvalid, /A line of a posted entry \(id #{line.id}\) cannot be changed/) { line.update_columns(amount_cents: 1) }
      rejected(ActiveRecord::StatementInvalid, /A line of a posted entry .* cannot be deleted/) { line.delete }
    end

    it "can be touched, and drafts can be changed freely" do
      expect { entry.touch }.not_to raise_error
      draft = entry(posted: false)
      expect { draft.update_columns(particulars: "Edited") }.not_to raise_error
      expect { TudlaAccounting::Detail.where(entry_id: draft.id).delete_all && TudlaAccounting::Entry.where(id: draft.id).delete_all }.not_to raise_error
    end

    it "can be purged inside allowing_posted_changes, and only there" do
      posted = entry
      TudlaAccounting::DatabaseProtection.allowing_posted_changes do
        TudlaAccounting::Detail.where(entry_id: posted.id).delete_all
        TudlaAccounting::Entry.where(id: posted.id).delete_all
      end
      expect(TudlaAccounting::Entry.exists?(posted.id)).to be(false)

      again = entry
      rejected(ActiveRecord::StatementInvalid, /cannot be changed/) { again.update_columns(particulars: "Edited") }
    end

    it "keeps protecting posted entries after a block that fails" do
      posted = entry
      expect { described_class_allowing { raise ArgumentError, "boom" } }.to raise_error(ArgumentError, "boom")
      rejected(ActiveRecord::StatementInvalid, /cannot be changed/) { posted.update_columns(particulars: "Edited") }
    end

    def described_class_allowing(&block) = TudlaAccounting::DatabaseProtection.allowing_posted_changes(&block)
  end

  describe TudlaAccounting::DatabaseProtection do
    it "installs and uninstalls its triggers" do
      expect(described_class.installed?).to be(true)
      described_class.uninstall!
      expect(described_class.installed?).to be(false)
      expect { entry.update_columns(particulars: "Edited") }.not_to raise_error
      described_class.install!
      expect(described_class.installed?).to be(true)
    end

    it "does nothing on databases other than PostgreSQL" do
      sqlite = double(adapter_name: "SQLite")
      expect(described_class.supported?(sqlite)).to be(false)
      expect(described_class.installed?(sqlite)).to be(false)
      expect(described_class.install!(sqlite)).to be_nil
      expect(described_class.uninstall!(sqlite)).to be_nil

      allow(sqlite).to receive(:transaction).with(requires_new: true).and_yield
      expect(described_class.allowing_posted_changes(sqlite) { :ran }).to eq(:ran)
    end
  end

  describe "after a schema load" do
    it "is prepended to Rails' schema loading" do
      expect(ActiveRecord::Tasks::DatabaseTasks.singleton_class.ancestors).to include(TudlaAccounting::DatabaseProtection::SchemaLoading)
    end

    it "puts the triggers back on the database the schema went into" do
      tasks = Class.new do
        def load_schema(*_args) = :loaded
        def migration_connection = ActiveRecord::Base.connection
      end
      tasks.prepend(TudlaAccounting::DatabaseProtection::SchemaLoading)
      TudlaAccounting::DatabaseProtection.uninstall!(ActiveRecord::Base.connection)

      expect(tasks.new.load_schema(:config, :ruby)).to eq(:loaded)
      expect(TudlaAccounting::DatabaseProtection.installed?(ActiveRecord::Base.connection)).to be(true)
    end
  end
end
