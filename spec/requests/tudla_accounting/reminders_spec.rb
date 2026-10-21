require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"
require_relative "../../support/test_jobs"

RSpec.describe "Overdue reminders", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include_context "with the test job adapter"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %i[read record post] }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", email: "ap@northwind.test") }
  let(:globex) { TudlaAccounting::Contact.create!(organization: organization, name: "Globex") }

  before do
    travel_to Time.zone.local(2026, 4, 20, 9)
    TudlaAccounting.configuration.authorize = ->(_controller, permission) { permissions.include?(permission) }
    TudlaAccounting.configuration.document_mail_from = "accounts@acme.test"
    TudlaAccounting.configuration.reminder_days = [ 7, 14 ]
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([ { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "4000", name: "Sales", category: "income" } ], organization)
  end

  after { travel_back }

  def invoice(contact, due_on)
    TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: contact, issued_on: Date.new(2026, 3, 1), due_on: due_on,
                                      lines_attributes: [ { description: "Work", unit_price_cents: 100_00, account: TudlaAccounting::Account.find_by!(organization: organization, code: "4000") } ]).approve!
  end

  def rows = css_select("tr[data-reminder]").map { |row| row.text.squish }

  it "lists the reminders due, sends them all once, and names those it can't" do
    invoice(northwind, Date.new(2026, 4, 1))
    invoice(globex, Date.new(2026, 4, 10))
    invoice(northwind, Date.new(2026, 4, 30))
    get routes.sales_documents_path
    expect(css_select("a[href='#{routes.reminders_path}']").map(&:text)).to eq([ "Reminders due (2)" ])

    get routes.reminders_path
    expect(rows).to eq([ "INV-0001 Northwind 1 Apr 2026 19 100.00 2nd reminder (14 days)", "INV-0002 Globex No email address 10 Apr 2026 10 100.00 1st reminder (7 days)" ])
    expect(response.body).to include("Send 2 reminders")

    post routes.reminders_path
    expect(response).to redirect_to(routes.reminders_path)
    expect(flash[:notice]).to eq("Emailing 1 reminder.")
    expect(flash[:alert]).to eq("Not reminded, as they have no email address: Globex.")
    expect(TudlaAccounting::Delivery.sole).to have_attributes(kind: "reminder", stage: 14, requested_by: "Demo user")
    get routes.reminders_path
    expect(rows.map(&:split).map(&:first)).to eq(%w[INV-0002])

    globex.update!(email: "ap@globex.test")
    post routes.reminders_path
    perform_enqueued_jobs
    post routes.reminders_path
    expect(flash[:notice]).to eq("No reminders are due.")
    expect(flash[:alert]).to be_nil
    get routes.reminders_path
    expect(response.body).to include("No reminders are due.")
    get routes.activity_path(kind: "email")
    expect(response.body).to include("a reminder of", "Invoice INV-0001 – Northwind")
  end

  it "sends one by hand from an overdue invoice's page" do
    overdue = invoice(northwind, Date.new(2026, 4, 15))
    current = invoice(northwind, Date.new(2026, 4, 30))
    get routes.document_path(current)
    expect(response.body).not_to include("Send reminder")
    get routes.new_email_path(document_id: current.id, reminder: 1)
    expect(response).to have_http_status(:not_found)

    get routes.document_path(overdue)
    expect(css_select("a[href='#{routes.new_email_path(document_id: overdue.id, reminder: 1)}']").map(&:text)).to eq([ "Send reminder" ])
    get routes.new_email_path(document_id: overdue.id, reminder: 1)
    expect(css_select("h1").first.text).to eq("Email a reminder of invoice INV-0001")
    expect(css_select("input[name='delivery[subject_line]']").first["value"]).to eq("Reminder: invoice INV-0001 is overdue")
    post routes.emails_path(document_id: overdue.id, reminder: 1), params: { delivery: { to: "ap@northwind.test", subject_line: "Reminder", message: "Please pay" } }
    expect(response).to redirect_to(routes.document_path(overdue))
    expect(TudlaAccounting::Delivery.sole).to have_attributes(kind: "reminder", stage: nil) # 5 days overdue: before the first reminder day

    travel_to Time.zone.local(2026, 4, 23, 9)
    post routes.emails_path(document_id: overdue.id, reminder: 1), params: { delivery: { to: "ap@northwind.test", subject_line: "Reminder", message: "Please pay" } }
    expect(TudlaAccounting::Delivery.order(:id).last.stage).to eq(7)
    get routes.reminders_path
    expect(rows).to eq([]) # the 7-day reminder has gone
  end

  context "without reminder days" do
    before { TudlaAccounting.configuration.reminder_days = [] }

    it "explains how to set them up" do
      invoice(northwind, Date.new(2026, 4, 1))
      get routes.reminders_path
      expect(response.body).to include("Reminders aren&#39;t set up", "reminder_days")
      get routes.sales_documents_path
      expect(css_select("a[href='#{routes.reminders_path}']").map(&:text)).to eq([ "Reminders due" ])
    end
  end

  context "without permission to post" do
    let(:permissions) { %i[read record] }

    it "lists them but sends none" do
      invoice(northwind, Date.new(2026, 4, 1))
      get routes.reminders_path
      expect(response.body).not_to include("Send 1 reminder")
      post routes.reminders_path
      expect(response).to have_http_status(:forbidden)
    end
  end
end
