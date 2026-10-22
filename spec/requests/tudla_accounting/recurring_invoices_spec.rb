require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"
require_relative "../../support/test_jobs"

RSpec.describe "Recurring invoices", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include_context "with the test job adapter"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %i[read record post] }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "customer", email: "ap@northwind.test", payment_terms_days: 14) }

  before do
    travel_to Time.zone.local(2026, 3, 15, 9)
    TudlaAccounting.configuration.authorize = ->(_controller, permission) { permissions.include?(permission) }
    TudlaAccounting.configuration.document_mail_from = "accounts@acme.test"
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "2200", name: "GST", category: "liability" },
      { code: "4000", name: "Sales", category: "income" }
    ], organization)
    @gst = TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: account("2200"))
    @eng = TudlaAccounting::Dimension.create!(organization: organization, code: "DEPT", name: "Department").dimension_values.create!(code: "ENG", name: "Engineering")
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def retainer = TudlaAccounting::RecurringInvoice.find_by!(organization: organization, name: "Retainer")
  def rows = css_select("tbody tr[data-recurring-invoice]").map { |row| row.css("td").map { |cell| cell.text.squish } }

  def form(**overrides)
    { name: "Retainer", contact_id: northwind.id, reference: "PO 7", notes: "Thank you", due_days: "", issue: "draft", frequency: "monthly", interval: "1",
      day_of_month: "1", starts_on: "2026-01-01", ends_on: "", occurrences_limit: "", tax_inclusive: "0",
      lines: { "0" => { description: "Retainer", quantity: "2", unit_price: "1,000", account_id: account("4000").id, tax_code_id: @gst.id, dimensions: { @eng.dimension_id.to_s => @eng.id } },
               "1" => { description: "", quantity: "1", unit_price: "", account_id: "" } } }.merge(overrides)
  end

  it "creates one from the form, showing it and when it is next due" do
    get routes.sales_documents_path
    expect(css_select("a[href='#{routes.recurring_invoices_path}']")).not_to be_empty
    get routes.recurring_invoices_path
    expect(response.body).to include("None yet.")
    get routes.new_recurring_invoice_path(contact_id: northwind.id)
    expect(css_select("select[name='recurring_invoice[contact_id]'] option[selected]").map(&:text)).to eq([ "Northwind" ])
    expect(css_select("select[name='recurring_invoice[lines][0][account_id]']")).not_to be_empty

    post routes.recurring_invoices_path, params: { recurring_invoice: form }
    expect(response).to redirect_to(routes.recurring_invoice_path(retainer))
    expect(flash[:notice]).to eq("Recurring invoice saved. The next invoice is due on 1 Jan 2026.")
    expect(retainer).to have_attributes(contact: northwind, reference: "PO 7", notes: "Thank you", due_days: nil, issue: "draft")
    expect(retainer.lines.map { |line| [ line.description, line.quantity, line.unit_price_cents, line.account.code, line.tax_code, line.dimension_value_ids ] })
      .to eq([ [ "Retainer", 2, 1_000_00, "4000", @gst, [ @eng.id ] ] ])

    get routes.recurring_invoices_path
    expect(rows).to eq([ [ "Retainer", "Northwind", "Every month on the 1st", "1 Jan 2026 Due", "Drafts to check and approve", "2,200.00" ] ])
    get routes.recurring_invoice_path(retainer)
    expect(css_select("tr[data-template-line]").map { |row| row.css("td").map { |cell| cell.text.squish } })
      .to eq([ [ "Retainer", "2", "1,000.00", "4000 - Sales", "GST (10%)", "Engineering", "2,000.00" ] ])
    expect(response.body).to include("On Northwind&#39;s payment terms", "Thank you", "PO 7")
  end

  it "shows what is wrong, keeping what was typed, and lets only those who post approve or email" do
    post routes.recurring_invoices_path, params: { recurring_invoice: form(day_of_month: "last", lines: { "0" => { description: "Retainer", unit_price: "lots", account_id: account("4000").id } }) }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Line 1: lots isn&#39;t an amount")
    expect(css_select("select[name='recurring_invoice[day_of_month]'] option[selected]").map(&:text)).to eq([ "Last day" ])

    permissions.delete(:post)
    get routes.new_recurring_invoice_path
    expect(css_select("input[name='recurring_invoice[issue]'][disabled]").map { |input| input["value"] }).to eq(%w[approve email])
    post routes.recurring_invoices_path, params: { recurring_invoice: form(issue: "email") }
    expect(response.body).to include("You can set it up to make drafts, but not to approve or email them")
    post routes.recurring_invoices_path, params: { recurring_invoice: form }
    expect(response).to redirect_to(routes.recurring_invoice_path(retainer))
  end

  it "makes the invoices due, approved and emailed, and a one-off draft for today" do
    post routes.recurring_invoices_path, params: { recurring_invoice: form(issue: "email", due_days: "7") }
    get routes.root_path
    expect(css_select("[data-recurring-invoices-due]").first.text.squish).to include("1 recurring invoice is due.")

    post routes.run_recurring_invoices_path
    expect(flash[:notice]).to eq("Made 3 invoices: 3 approved, 3 emailed.")
    expect(retainer.invoices.order(:issued_on).map { |invoice| [ invoice.number_label, invoice.issued_on, invoice.due_on, invoice.total_cents ] })
      .to eq([ [ "INV-0001", Date.new(2026, 1, 1), Date.new(2026, 1, 8), 2_200_00 ], [ "INV-0002", Date.new(2026, 2, 1), Date.new(2026, 2, 8), 2_200_00 ],
               [ "INV-0003", Date.new(2026, 3, 1), Date.new(2026, 3, 8), 2_200_00 ] ])
    expect(TudlaAccounting::Delivery.pluck(:to).uniq).to eq([ "ap@northwind.test" ])
    post routes.run_recurring_invoices_path
    expect(flash[:notice]).to eq("No invoices were due.")

    get routes.activity_path(kind: "recurring_invoice")
    expect(css_select("tbody tr").map { |row| row.css("td").last.text.squish }).to include("Made the invoice for 1 Mar 2026 from Retainer", "Added the recurring invoice Retainer")

    post routes.make_recurring_invoice_path(retainer)
    draft = retainer.invoices.order(:id).last
    expect(response).to redirect_to(routes.document_path(draft))
    expect(draft).to have_attributes(status: "draft", issued_on: Date.new(2026, 3, 15), idempotency_key: nil)
    expect(retainer.reload.occurrences_count).to eq(3) # apart from the schedule

    get routes.document_path(draft)
    expect(css_select("a[href='#{routes.recurring_invoice_path(retainer)}']").map(&:text)).to eq([ "Retainer" ])
    get routes.recurring_invoice_path(retainer)
    expect(css_select("tr[data-made-invoice]").size).to eq(4)
  end

  it "says what went wrong, on the list, its page and the dashboard" do
    post routes.recurring_invoices_path, params: { recurring_invoice: form }
    TudlaAccounting::Account.where(id: account("4000").id).update_all(active: false)
    post routes.run_recurring_invoices_path
    expect(flash[:alert]).to eq("Not everything went through: Retainer: 1 Jan 2026: Lines account is inactive.")
    get routes.recurring_invoices_path
    expect(response.body).to include("1 Jan 2026: Lines account is inactive")

    get routes.root_path
    expect(css_select("[data-recurring-invoices-due]").first.text.squish).to include("1 recurring invoice had a problem last time.")
    post routes.make_recurring_invoice_path(retainer)
    expect(flash[:alert]).to eq("No draft was made: lines account is inactive.")
  end

  it "repeats an invoice from its page" do
    invoice = TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: northwind, issued_on: Date.new(2026, 3, 1), due_on: Date.new(2026, 3, 31),
                                                reference: "PO 9", tax_inclusive: true, lines_attributes: [ { description: "Hosting", quantity: 1, unit_price_cents: 50_00, account: account("4000"),
                                                                                                                tax_code: @gst, dimension_value_ids: [ @eng.id ] } ]).approve!
    get routes.document_path(invoice)
    expect(css_select("a").map { |link| link["href"] }).to include(routes.new_recurring_invoice_path(document_id: invoice.id))

    get routes.new_recurring_invoice_path(document_id: invoice.id)
    expect(css_select("input[name='recurring_invoice[name]']").first["value"]).to eq("Northwind – Hosting")
    expect(css_select("input[name='recurring_invoice[due_days]']").first["value"]).to eq("30")
    expect(css_select("input[name='recurring_invoice[tax_inclusive]'][checked]")).not_to be_empty
    line = css_select("tbody[data-document-lines-target=lines] tr").sole
    expect(line.css("input[name$='[unit_price]']").first["value"]).to eq("50.00")
    expect(line.css("select[name$='[#{@eng.dimension_id}]'] option[selected]").map(&:text)).to eq([ "Engineering" ])
  end

  it "edits, deactivates and deletes one, on the activity log" do
    post routes.recurring_invoices_path, params: { recurring_invoice: form }
    template = retainer
    line = template.lines.sole
    patch routes.recurring_invoice_path(template), params: { recurring_invoice: form(lines: { "0" => { id: line.id, _destroy: "1" } }) }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Add at least one line")

    get routes.edit_recurring_invoice_path(template)
    expect(css_select("input[name='recurring_invoice[active]']")).not_to be_empty
    patch routes.recurring_invoice_path(template), params: { recurring_invoice: form(day_of_month: "last", active: "0", ends_on: "2026-01-15", lines: {
      "0" => { id: line.id, description: "Retainer", quantity: "1", unit_price: "1000", account_id: account("4000").id, tax_code_id: "", dimensions: { @eng.dimension_id.to_s => "" } }
    }) }
    expect(flash[:notice]).to eq("Recurring invoice saved. Its schedule has run out.")
    expect(template.reload).to have_attributes(day_of_month: nil, active: false, next_on: nil)
    expect(template.lines.sole).to have_attributes(tax_code: nil, dimension_value_ids: [])
    get routes.recurring_invoices_path
    expect(rows.sole).to include("Retainer Inactive", "Finished")

    delete routes.recurring_invoice_path(template)
    expect(flash[:notice]).to eq("Recurring invoice Retainer deleted. The invoices made from it stay.")
    get routes.activity_path(kind: "recurring_invoice")
    expect(css_select("tbody tr").map { |row| row.css("td").last.text.squish })
      .to eq([ "Deleted the recurring invoice Retainer", "Changed the recurring invoice Retainer: active, ends on, day of month", "Added the recurring invoice Retainer" ])
  end

  context "when allowed only to read" do
    let(:permissions) { %i[read] }

    it "shows them but changes nothing" do
      TudlaAccounting::RecurringInvoice.new(organization: organization, name: "Retainer", contact: northwind, frequency: "monthly", starts_on: Date.new(2026, 1, 1), due_days: 7)
                                       .tap { |template| template.lines.build(description: "Retainer", unit_price_cents: 100_00, account: account("4000")) }.save!
      get routes.recurring_invoice_path(retainer)
      expect(response.body).to include("7 days after its date")
      expect(response.body).not_to include("Make a draft for today")
      post routes.run_recurring_invoices_path
      expect(response).to have_http_status(:forbidden)
      post routes.make_recurring_invoice_path(retainer)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
