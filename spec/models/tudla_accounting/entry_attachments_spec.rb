require "rails_helper"
require_relative "../../support/configuration"

RSpec.describe "Entry attachments" do
  include_context "with isolated TudlaAccounting configuration"

  let(:organization) { create(:organization, currency: "USD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let(:cash) { create(:tudla_accounting_account, code: "1000", category: :asset, organization: organization) }
  let(:capital) { create(:tudla_accounting_account, code: "3000", category: :equity, organization: organization) }

  def draft
    entry = build(:tudla_accounting_entry, organization: organization, particulars: "Capital", transacted_at: Time.zone.local(2026, 2, 1))
    entry.details.build(account: cash, tally: :debit, amount_cents: 100_00, currency: "USD")
    entry.details.build(account: capital, tally: :credit, amount_cents: 100_00, currency: "USD")
    entry.tap(&:save!)
  end

  def posted = draft.tap { |entry| entry.post(entry.transacted_at) }
  def file(name) = { io: File.open(file_fixture(name)), filename: name, content_type: "application/octet-stream" }
  def events(action) = TudlaAccounting::AuditEvent.where(organization: organization, action: action)

  it "is available when Active Storage is loaded and has its tables" do
    expect(TudlaAccounting.attachments?).to be(true)
    allow(ActiveStorage::Blob).to receive(:table_exists?).and_return(false)
    expect(TudlaAccounting.attachments?).to be(false)
    expect { draft.add_attachments!(file("receipt.pdf")) }.to raise_error(ArgumentError, "Attachments need Active Storage")
  end

  it "attaches files to a posted entry, identifying them by their contents, on the audit trail" do
    entry = posted
    blobs = entry.add_attachments!([ file("receipt.pdf") ])

    expect(entry.reload.attachments.map { |attachment| [ attachment.filename.to_s, attachment.content_type ] }).to eq([ [ "receipt.pdf", "application/pdf" ] ])
    expect(events("entry.attachment_added").sole).to have_attributes(subject: entry, details: {
      "filename" => "receipt.pdf", "content_type" => "application/pdf", "byte_size" => blobs.first.byte_size, "checksum" => blobs.first.checksum
    })
  end

  it "attaches nothing when one file isn't allowed, saying why" do
    entry = draft
    expect { entry.add_attachments!([ file("receipt.pdf"), file("page.html") ]) }
      .to raise_error(ArgumentError, "page.html isn't a kind of file that can be attached (text/html)")
    TudlaAccounting.configuration.attachment_max_size = 100
    expect { entry.add_attachments!(file("receipt.pdf")) }.to raise_error(ArgumentError, "receipt.pdf is bigger than 100 Bytes")
    expect { entry.add_attachments!([ nil, "" ]) }.to raise_error(ArgumentError, "Choose a file to attach")

    expect(entry.reload.attachments).to be_empty
    expect(ActiveStorage::Blob.count).to eq(0) # the refused uploads are deleted again
    expect(events("entry.attachment_added")).to be_empty
  end

  it "removes a draft's file freely" do
    entry = draft
    entry.add_attachments!(file("receipt.pdf"))
    entry.remove_attachment!(entry.attachments.first)

    expect(entry.reload.attachments).to be_empty
    expect(ActiveStorage::Blob.count).to eq(0)
    expect(events("entry.attachment_removed").sole.details).to include("filename" => "receipt.pdf")
  end

  it "removes a posted entry's file only with a reason, kept on the audit trail" do
    entry = posted
    entry.add_attachments!(file("receipt.pdf"))
    attachment = entry.attachments.first

    expect { entry.remove_attachment!(attachment, reason: " ") }.to raise_error(ArgumentError, "Give a reason for removing a file from a posted entry")
    entry.remove_attachment!(attachment, reason: "Belongs to the March rent")
    expect(entry.reload.attachments).to be_empty
    expect(events("entry.attachment_removed").sole.details).to include("filename" => "receipt.pdf", "reason" => "Belongs to the March rent",
                                                                       "checksum" => attachment.blob.checksum)
  end

  it "refuses another entry's file" do
    other = draft
    other.add_attachments!(file("receipt.pdf"))
    expect { draft.remove_attachment!(other.attachments.first) }.to raise_error(ArgumentError, "That file isn't attached to this entry")
  end

  it "takes a deleted draft's files with it" do
    entry = draft
    entry.add_attachments!(file("receipt.pdf"))
    expect { entry.destroy! }.to change(ActiveStorage::Attachment, :count).by(-1)
  end
end
