require "rails_helper"
require "rake"
require_relative "../support/configuration"

RSpec.describe "tudla_accounting:balances rake tasks" do
  include ActiveSupport::Testing::TimeHelpers

  let(:organization) { create(:organization) }
  let(:other) { create(:organization) }

  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("tudla_accounting:balances:check")
  end

  before do
    [ organization, other ].each do |org|
      year = TudlaAccounting::PeriodCreator.call(org, 2026)
      TudlaAccounting::AccountsCreator.call([ { code: "1000", name: "Cash", category: "asset" }, { code: "3100", name: "Capital", category: "equity" } ], org)
      cash, capital = %w[1000 3100].map { |code| TudlaAccounting::Account.find_by(organization: org, code: code) }
      entry = build(:tudla_accounting_entry, organization: org, transacted_at: Time.zone.local(2026, 2, 1))
      entry.details.build(account: cash, tally: :debit, amount_cents: 100_00, currency: "USD", organization: org)
      entry.details.build(account: capital, tally: :credit, amount_cents: 100_00, currency: "USD", organization: org)
      entry.save!
      entry.post(entry.transacted_at)
      TudlaAccounting::Balance.where(account: cash, period: year).update_all(ending_amount_cents: 1) if org == organization
    end
  end

  after { ENV.delete("ORGANIZATION") }

  def run(name)
    task = Rake::Task["tudla_accounting:balances:#{name}"]
    task.reenable
    task.invoke
  end

  it "lists the differences and exits with a failure, then rebuilds them away" do
    expect { expect { run(:check) }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) } }
      .to output(/^Organization:#{organization.id}  1000  2026-01-01  ending_amount_cents  stored 1  expected 10000\n.*^1 difference\(s\) found/m).to_stdout

    expect { run(:rebuild) }.to output(/Organization:#{organization.id}: 1 balance\(s\) corrected\nOrganization:#{other.id}: 0/).to_stdout
    expect { run(:check) }.to output(/^Balances agree with the posted entries.\n\z/).to_stdout
  end

  # Posted before only accounts without sub-accounts took postings: the balances add up,
  # so a warning.
  it "warns about accounts with sub-accounts holding amounts of their own" do
    ENV["ORGANIZATION"] = "Organization:#{other.id}"
    cash, capital = %w[1000 3100].map { |code| TudlaAccounting::Account.find_by!(organization: other, code: code) }
    TudlaAccounting::StartingBalanceCreator.call(other, Date.new(2026, 1, 1), [ { account_id: cash.id, amount_cents: 5_00 }, { account_id: capital.id, amount_cents: 5_00 } ], "USD", true)
    till = build(:tudla_accounting_account, code: "1010", category: :asset, organization: other, parent: cash)
    TudlaAccounting::DatabaseProtection.allowing_posted_changes { till.save!(validate: false) }

    expect { run(:check) }.to output(<<~OUTPUT).to_stdout
      Organization:#{other.id}  warning: no account is marked as the Retained earnings account
      Organization:#{other.id}  warning: 1000 has sub-accounts but holds 1 posted line(s) and an opening balance of 500 of its own
      Balances agree with the posted entries.
    OUTPUT
  end

  # Books without them are allowed, so these are warnings, not failures. Receivables and
  # payables are only expected once a carrying amount source records them.
  context "with invoices recorded as receivables" do
    include_context "with isolated TudlaAccounting configuration"

    before { TudlaAccounting.configuration.carrying_amount_sources = { "Invoice" => :receivable } }

    it "warns about the accounts with no receivable or retained earnings account marked" do
      ENV["ORGANIZATION"] = "Organization:#{other.id}"
      expect { run(:check) }.to output(<<~OUTPUT).to_stdout
        Organization:#{other.id}  warning: no account is marked as the Receivables account
        Organization:#{other.id}  warning: no account is marked as the Retained earnings account
        Balances agree with the posted entries.
      OUTPUT

      TudlaAccounting::AccountsCreator.call([ { code: "1100", name: "Receivables", category: "asset", role: "receivable" },
                                              { code: "3900", name: "Retained earnings", category: "equity", role: "retained_earnings" } ], other)
      expect { run(:check) }.to output("Balances agree with the posted entries.\n").to_stdout
    end
  end
end

RSpec.describe "tudla_accounting:protect_posted_entries rake task" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("tudla_accounting:protect_posted_entries")
  end

  it "installs the triggers protecting posted entries" do
    TudlaAccounting::DatabaseProtection.uninstall!(ActiveRecord::Base.connection)

    Rake::Task["tudla_accounting:protect_posted_entries"].tap(&:reenable).invoke

    expect(TudlaAccounting::DatabaseProtection.installed?(ActiveRecord::Base.connection)).to be(true)
  end
end
