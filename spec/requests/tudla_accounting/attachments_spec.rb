require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Attachments", type: :request do
  include_context "with isolated TudlaAccounting configuration"

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %i[read record post administer] }

  before do
    TudlaAccounting.configuration.authorize = ->(_controller, permission) { permissions.include?(permission) }
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([ { code: "1010", name: "Cash", category: "asset" }, { code: "3000", name: "Capital", category: "equity" } ], organization)
  end

  def account(code, org = organization) = TudlaAccounting::Account.find_by(organization: org, code: code)

  def entry(posted: false, org: organization)
    record = build(:tudla_accounting_entry, organization: org, particulars: "Capital", transacted_at: Time.zone.local(2026, 2, 10))
    record.details.build(account: account("1010", org), tally: :debit, amount_cents: 500, currency: "AUD", organization: org)
    record.details.build(account: account("3000", org), tally: :credit, amount_cents: 500, currency: "AUD", organization: org)
    record.save!
    record.post(record.transacted_at) if posted
    record
  end

  def upload(name, type = "application/pdf") = fixture_file_upload(name, type)
  def attach(record) = record.add_attachments!(io: File.open(file_fixture("receipt.pdf")), filename: "receipt.pdf", content_type: "application/pdf").first

  it "uploads files to an entry and lists them" do
    record = entry(posted: true)
    post routes.entry_attachments_path(record), params: { files: [ upload("receipt.pdf") ] }
    expect(response).to redirect_to(routes.entry_path(record))
    expect(flash[:notice]).to eq("receipt.pdf attached.")

    get routes.entry_path(record)
    expect(css_select("[data-attachment] td:first-child").map(&:text)).to eq([ "receipt.pdf" ])
    expect(css_select("input[name=reason]")).not_to be_empty # a posted entry's file needs a reason to go

    get routes.entries_path
    expect(css_select("[data-attachments]").map { |tag| tag["title"] }).to eq([ "1 attachment" ])
  end

  it "says why nothing was attached" do
    record = entry
    post routes.entry_attachments_path(record), params: { files: [ upload("page.html", "application/pdf") ] }
    expect(flash[:alert]).to eq("Nothing was attached: page.html isn't a kind of file that can be attached (text/html).")
    post routes.entry_attachments_path(record)
    expect(flash[:alert]).to eq("Nothing was attached: choose a file to attach.")
  end

  it "serves a file through the engine, inline or as a download" do
    record = entry
    attachment = record.attachments.find_by!(blob: attach(record))

    get routes.entry_attachment_path(record, attachment)
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/pdf")
    expect(response.headers["Content-Disposition"]).to start_with("inline")
    expect(response.body).to start_with("%PDF")

    get routes.entry_attachment_path(record, attachment, download: 1)
    expect(response.headers["Content-Disposition"]).to start_with("attachment")
  end

  it "keeps another organization's files to itself" do
    other = create(:organization, currency: "AUD")
    TudlaAccounting::AccountsCreator.call([ { code: "1010", name: "Cash", category: "asset" }, { code: "3000", name: "Capital", category: "equity" } ], other)
    theirs = entry(org: other)
    attachment = theirs.attachments.find_by!(blob: attach(theirs))

    get routes.entry_attachment_path(theirs, attachment)
    expect(response).to have_http_status(:not_found)
    get routes.entry_attachment_path(entry, attachment) # someone else's file through an entry of ours
    expect(response).to have_http_status(:not_found)
  end

  context "when allowed only to read" do
    let(:permissions) { %i[read] }

    it "shows the files, but neither uploads nor removes them" do
      record = entry
      attachment = record.attachments.find_by!(blob: attach(record))

      get routes.entry_path(record)
      expect(css_select("[data-attachment]").size).to eq(1)
      expect(css_select("input[type=file]")).to be_empty
      expect(css_select("form[action='#{routes.entry_attachment_path(record, attachment)}']")).to be_empty

      post routes.entry_attachments_path(record), params: { files: [ upload("receipt.pdf") ] }
      expect(response).to have_http_status(:forbidden)
      delete routes.entry_attachment_path(record, attachment)
      expect(response).to have_http_status(:forbidden)
      expect(record.attachments.count).to eq(1)
    end
  end

  context "when recording but not administering" do
    let(:permissions) { %i[read record post] }

    it "removes a draft's file, but not a posted entry's" do
      draft = entry
      delete routes.entry_attachment_path(draft, draft.attachments.find_by!(blob: attach(draft)))
      expect(flash[:notice]).to eq("receipt.pdf removed.")
      expect(draft.attachments.count).to eq(0)

      record = entry(posted: true)
      attachment = record.attachments.find_by!(blob: attach(record))
      get routes.entry_path(record)
      expect(css_select("input[name=reason]")).to be_empty
      delete routes.entry_attachment_path(record, attachment), params: { reason: "Wrong entry" }
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "removes a posted entry's file for an administrator who gives a reason" do
    record = entry(posted: true)
    attachment = record.attachments.find_by!(blob: attach(record))

    delete routes.entry_attachment_path(record, attachment)
    expect(flash[:alert]).to eq("Give a reason for removing a file from a posted entry.")
    delete routes.entry_attachment_path(record, attachment), params: { reason: "Wrong entry" }
    expect(flash[:notice]).to eq("receipt.pdf removed.")

    get routes.activity_path
    expect(css_select("tbody tr").map { |row| row.css("td").last.text.squish }).to include(
      "Removed receipt.pdf from #1 Capital: “Wrong entry”", "Attached receipt.pdf to #1 Capital"
    )
  end

  it "leaves attachments out without Active Storage" do
    record = entry
    allow(TudlaAccounting).to receive(:attachments?).and_return(false)

    get routes.entry_path(record)
    expect(response.body).not_to include("Attachments")
    get routes.entries_path
    expect(response).to have_http_status(:ok)
    post routes.entry_attachments_path(record), params: { files: [ upload("receipt.pdf") ] }
    expect(response).to have_http_status(:not_found)
  end
end
