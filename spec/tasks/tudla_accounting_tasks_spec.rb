require "rails_helper"
require "rake"

RSpec.describe "tudla_accounting:balances rake tasks" do
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
      .to output(/Organization:#{organization.id}  1000  2026-01-01  ending_amount_cents  stored 1  expected 10000\n1 difference\(s\) found/).to_stdout

    expect { run(:rebuild) }.to output(/Organization:#{organization.id}: 1 balance\(s\) corrected\nOrganization:#{other.id}: 0/).to_stdout
    expect { run(:check) }.to output("Balances agree with the posted entries.\n").to_stdout
  end

  it "checks just one organization when asked" do
    ENV["ORGANIZATION"] = "Organization:#{other.id}"
    expect { run(:check) }.to output("Balances agree with the posted entries.\n").to_stdout
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
