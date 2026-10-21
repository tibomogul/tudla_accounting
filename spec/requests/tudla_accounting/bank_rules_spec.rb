require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Bank rules", type: :request do
  include_context "with isolated TudlaAccounting configuration"

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %i[read record post administer] }

  before do
    TudlaAccounting.configuration.authorize = ->(_controller, permission) { permissions.include?(permission) }
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "2200", name: "GST", category: "liability" },
      { code: "6200", name: "Software", category: "expense" }, { code: "6300", name: "Bank fees", category: "expense" }
    ], organization)
    @gst = TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :purchases, account: account("2200"))
    @ops = TudlaAccounting::Dimension.create!(organization: organization, code: "DEPT", name: "Department").dimension_values.create!(code: "OPS", name: "Ops")
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def rule = TudlaAccounting::BankRule.find_by!(organization: organization)

  def line(description, cents)
    TudlaAccounting::BankStatementLine.create!(organization: organization, account: account("1000"), occurred_on: Date.new(2026, 3, 5), description: description,
                                               amount_cents: cents, currency: "AUD", external_id: SecureRandom.hex(8))
  end

  def form(**overrides)
    { name: "Adobe", position: "10", account_id: account("1000").id, description_contains: "adobe", direction: "out", amount_min: "", amount_max: "100",
      counter_account_id: account("6200").id, tax_code_id: @gst.id, particulars: "Adobe subscription", dimensions: { @ops.dimension_id.to_s => @ops.id } }.merge(overrides)
  end

  it "adds a rule, lists it, edits and deletes it, on the activity log" do
    get routes.new_bank_rule_path
    expect(css_select("input[name='bank_rule[position]']").first["value"]).to eq("10")

    post routes.bank_rules_path, params: { bank_rule: form }
    expect(response).to redirect_to(routes.bank_rules_path)
    expect(rule).to have_attributes(direction: "out", amount_min_cents: nil, amount_max_cents: 100_00, tax_code: @gst, dimension_value_ids: [ @ops.id ])

    get routes.bank_rules_path
    expect(css_select("tr[data-bank-rule] td").map { |cell| cell.text.squish })
      .to eq([ "10", "Adobe", "containing “adobe”, money out, to 100.00 On 1000 - Bank", "6200 - Software, GST, Ops" ])

    patch routes.bank_rule_path(rule), params: { bank_rule: form(amount_max: "lots") }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Amount max: lots isn&#39;t an amount")
    patch routes.bank_rule_path(rule), params: { bank_rule: form(account_id: "", tax_code_id: "", direction: "", dimensions: { @ops.dimension_id.to_s => "" }, active: "0") }
    expect(rule).to have_attributes(account: nil, tax_code: nil, direction: nil, dimension_value_ids: [], active: false)

    get routes.activity_path(kind: "bank_rule")
    expect(css_select("a[href='#{routes.edit_bank_rule_path(rule)}']").map(&:text)).to include("Adobe")

    delete routes.bank_rule_path(rule)
    expect(flash[:notice]).to eq("Bank rule Adobe deleted.")
    get routes.activity_path(kind: "bank_rule")
    expect(css_select("tbody tr").map { |row| row.css("td").last.text.squish }.last).to eq("Added the bank rule Adobe")
  end

  it "starts one from a statement line" do
    software = line("ADOBE *CREATIVE CLOUD", -55_00)
    get routes.new_bank_rule_path(line_id: software.id)
    expect(css_select("input[name='bank_rule[description_contains]']").first["value"]).to eq("ADOBE *CREATIVE CLOUD")
    expect(css_select("select[name='bank_rule[direction]'] option[selected]").map(&:text)).to eq([ "Money out" ])
    expect(css_select("select[name='bank_rule[account_id]'] option[selected]").map(&:text)).to eq([ "1000 - Bank" ])
  end

  it "suggests and records lines by their rules on the banking page" do
    software = line("ADOBE *CREATIVE CLOUD", -55_00)
    fee = line("Account fee", -10_00)
    line("Deposit", 500_00)
    post routes.bank_rules_path, params: { bank_rule: form }
    post routes.bank_rules_path, params: { bank_rule: form(name: "Fees", description_contains: "fee", counter_account_id: account("6300").id, tax_code_id: "", particulars: "", dimensions: {}) }

    get routes.banking_account_path(account("1000"))
    expect(css_select("[data-rule-suggestion] span").map { |span| span.text.squish })
      .to eq([ "Rule Fees: 6300 - Bank fees", "Rule Adobe: 6200 - Software, GST, Ops" ]) # newest line first
    expect(css_select("form button").map(&:text)).to include("Record 2 lines by their rules")
    expect(css_select("a").map { |link| link["href"] }).to include(routes.new_bank_rule_path(line_id: software.id))

    post routes.record_by_rule_bank_statement_line_path(fee)
    expect(flash[:notice]).to eq("Posted Account fee and matched it.")
    post routes.record_by_rule_bank_statement_line_path(fee)
    expect(flash[:alert]).to eq("No rule suggests how to record Account fee.")

    post routes.banking_record_by_rules_path(account("1000"))
    expect(flash[:notice]).to eq("Recorded 1 statement line by their rules.")
    expect(software.reload.details.first.entry.particulars).to eq("Adobe subscription")
  end

  it "says why a line wasn't recorded" do
    software = line("ADOBE *CREATIVE CLOUD", -55_00)
    post routes.bank_rules_path, params: { bank_rule: form }
    TudlaAccounting::Period.where(organization: organization).find_each { |period| period.update_columns(closed_at: Time.current) unless period.root? }

    post routes.record_by_rule_bank_statement_line_path(software)
    expect(flash[:alert]).to start_with("It was not recorded: ")
    post routes.banking_record_by_rules_path(account("1000"))
    expect(flash[:alert]).to start_with("Some weren't recorded: ADOBE *CREATIVE CLOUD: ")
    expect(software.reload).not_to be_matched
  end

  context "when allowed to read and record, but not post" do
    let(:permissions) { %i[read record] }

    it "lists rules but neither changes nor applies them" do
      get routes.bank_rules_path
      expect(response.body).not_to include("New rule")
      post routes.bank_rules_path, params: { bank_rule: form }
      expect(response).to have_http_status(:forbidden)
      post routes.banking_record_by_rules_path(account("1000"))
      expect(response).to have_http_status(:forbidden)
    end
  end
end
