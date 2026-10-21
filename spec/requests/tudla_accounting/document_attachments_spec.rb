require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Files on invoices and bills", type: :request do
  include_context "with isolated TudlaAccounting configuration"

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %i[read record post administer] }
  let(:supplier) { TudlaAccounting::Contact.create!(organization: organization, name: "Paper Co", kind: "supplier") }

  before do
    TudlaAccounting.configuration.authorize = ->(_controller, permission) { permissions.include?(permission) }
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([ { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "6000", name: "Supplies", category: "expense" } ], organization)
  end

  def bill(approve: false)
    made = TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: supplier, issued_on: Date.new(2026, 3, 1),
                                             lines_attributes: [ { description: "Paper", unit_price_cents: 55_00, account: TudlaAccounting::Account.find_by!(organization: organization, code: "6000") } ])
    approve ? made.approve! : made
  end

  def upload = fixture_file_upload("receipt.pdf", "application/pdf")
  def attach(record)
    record.add_attachments!(io: File.open(file_fixture("receipt.pdf")), filename: "bill.pdf", content_type: "application/pdf")
    record.attachments.reload.last
  end

  it "attaches the supplier's PDF to a bill, serves it, and takes it off a draft freely" do
    draft = bill
    get routes.document_path(draft)
    expect(response.body).to include("No files attached.", "Attach files")

    post routes.document_attachments_path(draft), params: { files: [ upload ] }
    expect(response).to redirect_to(routes.document_path(draft))
    expect(flash[:notice]).to eq("receipt.pdf attached.")
    attachment = draft.attachments.sole
    get routes.document_path(draft)
    expect(css_select("[data-attachment] td:first-child").map(&:text)).to eq([ "receipt.pdf" ])
    get routes.document_attachment_path(draft, attachment, download: 1)
    expect(response.headers["Content-Disposition"]).to start_with("attachment")
    expect(response.body).to start_with("%PDF")

    delete routes.document_attachment_path(draft, attachment)
    expect(flash[:notice]).to eq("receipt.pdf removed.")
    expect(draft.attachments.reload).to be_empty
    post routes.document_attachments_path(draft)
    expect(flash[:alert]).to eq("Nothing was attached: choose a file to attach.")

    events = TudlaAccounting::AuditEvent.where(subject: draft, action: %w[document.attachment_added document.attachment_removed]).order(:id)
    expect(events.map(&:action)).to eq(%w[document.attachment_added document.attachment_removed])
    get routes.activity_path(kind: "document")
    expect(response.body).to include("Attached receipt.pdf to", "Removed receipt.pdf from")
  end

  it "keeps an approved document's files, taken off only by an administrator with a reason" do
    approved = bill(approve: true)
    attachment = attach(approved)
    get routes.document_path(approved)
    expect(response.body).to include("Files on an approved document stay with it", "Why remove it?")
    delete routes.document_attachment_path(approved, attachment)
    expect(flash[:alert]).to eq("Give a reason for removing a file from an approved document.")
    delete routes.document_attachment_path(approved, attachment), params: { reason: "Another supplier's bill" }
    expect(flash[:notice]).to eq("bill.pdf removed.")
    expect(TudlaAccounting::AuditEvent.where(action: "document.attachment_removed").sole.details).to include("reason" => "Another supplier's bill")
  end

  context "with permission to record but not administer" do
    let(:permissions) { %i[read record] }

    it "can't take a file off an approved document" do
      approved = bill(approve: true)
      delete routes.document_attachment_path(approved, attach(approved)), params: { reason: "x" }
      expect(response).to have_http_status(:forbidden)
      expect(approved.attachments.reload.size).to eq(1)
    end
  end

  it "keeps another organization's files apart" do
    other = create(:organization, currency: "AUD")
    TudlaAccounting::AccountsCreator.call([ { code: "6000", name: "Theirs", category: "expense" } ], other)
    theirs = TudlaAccounting::Document.create!(organization: other, kind: "bill", contact: TudlaAccounting::Contact.create!(organization: other, name: "Theirs", kind: "supplier"),
                                               issued_on: Date.new(2026, 3, 1), lines_attributes: [ { description: "x", unit_price_cents: 1, account: TudlaAccounting::Account.find_by!(organization: other, code: "6000") } ])
    get routes.document_attachment_path(theirs, attach(theirs))
    expect(response).to have_http_status(:not_found)
  end
end

RSpec.describe "JSON API: files on documents and entries", type: :request do
  include_context "with isolated TudlaAccounting configuration"

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %w[read record] }
  let(:secret) { TudlaAccounting::ApiToken.issue!(organization: organization, name: "Shop", permissions: permissions).last }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }
  let(:supplier) { TudlaAccounting::Contact.create!(organization: organization, name: "Paper Co", kind: "supplier") }
  let(:bill) do
    TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: supplier, issued_on: Date.new(2026, 3, 1),
                                      lines_attributes: [ { description: "Paper", unit_price_cents: 55_00, account: TudlaAccounting::Account.find_by!(organization: organization, code: "6000") } ])
  end

  before do
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([ { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "6000", name: "Supplies", category: "expense" } ], organization)
  end

  def json = JSON.parse(response.body)

  it "uploads a file, lists it with the document, and downloads it" do
    post routes.api_v1_document_attachments_path(bill), params: { file: fixture_file_upload("receipt.pdf", "application/pdf") }, headers: headers
    expect(response).to have_http_status(:created)
    expect(json["data"]).to match([ include("filename" => "receipt.pdf", "content_type" => "application/pdf", "byte_size" => be_positive) ])
    id = json["data"].first["id"]

    get routes.api_v1_document_path(bill), headers: headers
    expect(json.dig("data", "attachments").map { |file| file["id"] }).to eq([ id ])
    get routes.api_v1_document_attachment_path(bill, id), headers: headers
    expect(response.body).to start_with("%PDF")
    expect(response.headers["Content-Disposition"]).to start_with("attachment")

    post routes.api_v1_document_attachments_path(bill), params: { files: [ fixture_file_upload("page.html", "text/html") ] }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(json.dig("error", "message")).to start_with("Page.html isn't a kind of file that can be attached")
  end

  it "does the same for an entry" do
    entry = bill.approve!.entry
    post routes.api_v1_entry_attachments_path(entry), params: { file: fixture_file_upload("receipt.pdf", "application/pdf") }, headers: headers
    expect(response).to have_http_status(:created)
    get routes.api_v1_entry_path(entry), headers: headers
    expect(json.dig("data", "attachments").size).to eq(1)
  end

  it "has none without Active Storage" do
    allow(TudlaAccounting).to receive(:attachments?).and_return(false)
    get routes.api_v1_document_path(bill), headers: headers
    expect(json.dig("data", "attachments")).to eq([])
    post routes.api_v1_document_attachments_path(bill), params: { file: fixture_file_upload("receipt.pdf", "application/pdf") }, headers: headers
    expect(response).to have_http_status(:not_found)
  end

  context "with a read-only token" do
    let(:permissions) { %w[read] }

    it "can't upload" do
      post routes.api_v1_document_attachments_path(bill), params: { file: fixture_file_upload("receipt.pdf", "application/pdf") }, headers: headers
      expect(response).to have_http_status(:forbidden)
    end
  end
end
