require "rails_helper"
require "rake"
require_relative "../support/configuration"

# USAGE.md's console examples and rake commands, run as written, in the order the guide
# gives them, so the guide stays true. Its UI steps are followed in
# spec/system/usage_guide_spec.rb.
RSpec.describe "USAGE.md" do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:organization) { create(:organization, name: "Acme", currency: "USD") }
  let(:fixtures) { TudlaAccounting::Engine.root.join("spec/fixtures/files") }

  # The fenced blocks, each with the heading it's under.
  def self.blocks
    @blocks ||= begin
      block = Struct.new(:heading, :language, :code) # a local, so no constant leaks out of the spec
      heading = nil
      fence = nil
      TudlaAccounting::Engine.root.join("USAGE.md").each_line.with_object([]) do |line, blocks|
        if fence.nil? && line.start_with?("#")
          heading = line.sub(/\A#+\s*/, "").strip
        elsif fence.nil? && (match = line.match(/\A```(\w+)/))
          fence = block.new(heading, match[1], +"")
        elsif fence && line.start_with?("```")
          blocks << fence
          fence = nil
        elsif fence
          fence.code << line
        end
      end
    end
  end

  def ruby_blocks(except: [])
    self.class.blocks.select { |block| block.language == "ruby" && except.none? { |heading| block.heading == heading } }
  end

  around do |example|
    travel_to(Time.zone.local(2026, 6, 15, 9)) do
      Dir.mktmpdir do |dir|
        @dir = Pathname(dir)
        Dir.chdir(dir) { example.run }
      end
    end
  ensure
    TudlaAccounting::Current.reset
  end

  before do
    TudlaAccounting.configuration.forex_rate_provider = ->(from:, to:, date:) { 1.6 } # for the revaluation
    TudlaAccounting.configuration.reminder_days = [ 7, 14, 30 ] # as the guide's reminders have it
    # The files the examples name, in the directory they run in.
    FileUtils.cp(fixtures.join("coa_saas_services.xlsx"), @dir.join("chart.xlsx"))
    FileUtils.cp(fixtures.join("carrying_amounts.csv"), @dir.join("open_items.csv"))
    FileUtils.cp(fixtures.join("contacts.csv"), @dir.join("contacts.csv"))
    FileUtils.cp(fixtures.join("bank_statement.csv"), @dir.join("statement.csv"))
    roles = { "1020" => "receivable", "2011" => "payable", "3030" => "retained_earnings" }
    chart = CSV.read(fixtures.join("coa_saas_services.csv"), headers: true)
    @dir.join("chart.csv").write(CSV.generate do |csv|
      csv << chart.headers + [ "Role" ]
      chart.each { |row| csv << row.fields + [ roles[row["Account Code"]] ] }
    end)
  end

  # Runs the blocks one after another with shared local variables, as a console session
  # would, on this spec's organization rather than Organization.find(1).
  def run(blocks)
    session = binding
    blocks.each do |block|
      session.eval(block.code.gsub("Organization.find(1)", "Organization.find(#{organization.id})"), "USAGE.md (#{block.heading})")
    rescue StandardError, SyntaxError => e
      raise "USAGE.md example under \"#{block.heading}\" failed: #{e.class}: #{e.message}\n\n#{block.code}"
    end
    session
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def differences = TudlaAccounting::BalanceRebuilder.new(organization).differences

  it "sets up the books from Ruby, start to finish" do
    session = run(ruby_blocks(except: [ "From a spreadsheet (CSV or Excel)" ]))

    year = session.local_variable_get(:year)
    expect(year.children.count).to eq(12)
    expect(TudlaAccounting::Account::ROLES.keys.map { |role| TudlaAccounting::Account.for_role(organization, role)&.code })
      .to eq(%w[1100 2100 3900 4910 4900])
    expect(%w[1010 1500 1510 3100].map { |code| TudlaAccounting::Balance.peek(account(code), year).starting_amount.to_f }).to eq([ 25_000.0, 6_000.0, 1_000.0, 30_000.0 ])
    expect(TudlaAccounting::TaxCode.where(organization: organization).pluck(:code)).to contain_exactly("GST", "GST-P", "FRE")
    expect(TudlaAccounting::Dimension.find_by!(organization: organization, code: "DEPT").dimension_values.pluck(:code)).to eq(%w[ENG OPS SALES])
    contacts = TudlaAccounting::Contact.where(organization: organization).index_by(&:name)
    expect(contacts.keys).to contain_exactly("Northwind Traders", "Globex", "Initech Supplies", "Cloudnine Hosting")
    expect(contacts["Northwind Traders"]).to have_attributes(kind: "customer", payment_terms_days: 14, default_tax_code: have_attributes(code: "GST"))
    expect(contacts["Cloudnine Hosting"]).to have_attributes(default_account: account("6020"), default_tax_code: have_attributes(code: "GST-P"))
    expect(TudlaAccounting::CarryingAmount.joins(detail: :entry).where(tudla_accounting_details: { organization_id: organization.id })
                                          .where(tudla_accounting_entries: { source_type: nil }).count).to eq(3) # the open items imported

    # Running the books
    documents = TudlaAccounting::Document.where(organization: organization).order(:id)
    expect(documents.map { |document| [ document.number_label, document.payment_status, document.amount_due.format ] })
      .to eq([ [ "INV-0001", "paid", "$0.00" ], [ "BILL-0001", "paid", "$0.00" ], [ "INV-0002", "unpaid", "€1.000,00" ], [ "SC-0001", "paid", "$0.00" ], [ "INV-0003", "unpaid", "$550.00" ] ])
    expect(documents.third.entry.details.map { |detail| detail.account.code }).to include("1100-EUR")
    expect(TudlaAccounting::Payment.where(organization: organization).order(:id).map { |payment| [ payment.kind, payment.amount_cents ] })
      .to eq([ [ "received", 1_700_00 ], [ "refund", 50_00 ], [ "paid", 198_00 ] ])
    expect(TudlaAccounting::RecurringInvoice.find_by!(organization: organization).next_on).to eq(Date.new(2026, 7, 1))
    expect(TudlaAccounting::Delivery.where(organization: organization).order(:id).map { |delivery| [ delivery.kind, delivery.to ] })
      .to eq([ %w[payment_notice billing@cloudnine.test], %w[reminder payables@globex.test] ])
    bank_lines = TudlaAccounting::BankStatementLine.where(account: account("1010"))
    expect(bank_lines.count).to eq(4)
    expect(bank_lines.where.missing(:bank_matches).count).to eq(0)
    expect(TudlaAccounting::BankReconciler.new(account("1010")).summary(as_of: Date.new(2026, 6, 30))[:difference]).to eq(Money.new(0, "USD"))
    budget = TudlaAccounting::Budget.find_by!(organization: organization, main: true)
    expect(budget.amounts.transform_values { |months| months.values.sum }).to eq(account("4010").id => 24_000_00, account("6020").id => 2_400_00)
    expect(TudlaAccounting::Entry.where(organization: organization).where("particulars LIKE ?", "%Revaluation of%").count).to eq(2) # the revaluation and its reversal
    expect(year.children.order(:from_date).first.closed?).to be(false) # closed, then reopened
    expect(differences).to be_empty
  end

  it "loads the chart and opening balances from a spreadsheet" do
    run(ruby_blocks.select { |block| [ "Setting up the books", "2. Create a financial year", "From a spreadsheet (CSV or Excel)" ].include?(block.heading) })

    expect(TudlaAccounting::Account.where(organization: organization).count).to eq(83) # the file's 81, and the receivable and payable accounts' in USD
    expect(%w[receivable payable retained_earnings].map { |role| TudlaAccounting::Account.for_role(organization, role).code }).to eq(%w[1020 2011 3030])
    year = TudlaAccounting::Period.roots.find_by!(organization: organization)
    # The receivable account's opening balance is on its sub-account in USD, beside the allowance.
    expect(%w[1020 1020-USD 1025].map { |code| TudlaAccounting::Balance.peek(account(code), year).starting_amount.to_f }).to eq([ 20_000.0, 20_000.0, 1_000.0 ])
    expect(differences).to be_empty
  end

  # Each `bin/rails tudla_accounting:...` line in the guide, with its environment.
  it "runs the rake tasks the guide names" do
    run(ruby_blocks(except: [ "From a spreadsheet (CSV or Excel)" ]))
    Rails.application.load_tasks unless Rake::Task.task_defined?("tudla_accounting:balances:check")

    commands = self.class.blocks.select { |block| block.language == "bash" }.flat_map { |block| block.code.lines }
      .filter_map { |line| line.match(/bin\/rails (tudla_accounting:\S+)((?:\s+[A-Z_]+=\S+)*)/) }
    expect(commands.map { |command| command[1] }).to contain_exactly("tudla_accounting:protect_posted_entries", "tudla_accounting:balances:check",
                                                                     "tudla_accounting:balances:rebuild")

    commands.each do |command|
      env = command[2].split.to_h { |pair| pair.split("=", 2) }.transform_values { |value| value.sub(/\AOrganization:\d+\z/, "Organization:#{organization.id}") }
      output = with_env(env) { capture_stdout { Rake::Task[command[1]].tap(&:reenable).invoke } }
      expect(output).to include("Balances agree with the posted entries.") if command[1].end_with?(":check")
      expect(output).to include("Organization:#{organization.id}: 0 balance(s) corrected") if command[1].end_with?(":rebuild")
    end
  end

  def with_env(env)
    saved = env.keys.to_h { |key| [ key, ENV[key] ] }
    env.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
