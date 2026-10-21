# frozen_string_literal: true

module TudlaAccounting
  # An email of something to a customer or supplier (kind: an invoice or credit note
  # (document), a reminder, a statement, a receipt or a payment notice), with its PDF
  # attached when the engine can make PDFs. It is recorded queued, sent in the background
  # (DeliveryJob, through the document_mailer setting), and kept sent or failed, with the
  # error, so the pages show what went to whom.
  #
  #   Delivery.request!(subject: invoice, kind: "document", to: "ap@northwind.test",
  #                     subject_line: "Invoice INV-0001", message: "Please find attached...")
  #
  # Its subject is the document or payment, or for a statement its customer or supplier
  # (a contact, or a host app's record), with the statement's type and dates in details.
  class Delivery < ApplicationRecord
    KINDS = %w[document reminder statement receipt payment_notice].freeze
    ADDRESS = URI::MailTo::EMAIL_REGEXP

    belongs_to :organization, polymorphic: true
    belongs_to :subject, polymorphic: true

    normalizes :to, :cc, with: ->(addresses) { addresses.split(/[,;\s]+/).compact_blank.uniq.join(", ").presence }
    normalizes :subject_line, with: ->(line) { line.squish }

    validates :kind, inclusion: { in: KINDS }
    validates :status, inclusion: { in: %w[queued sent failed] }
    validates :to, :subject_line, :message, presence: true
    validates :subject_line, length: { maximum: 255 }
    validate :addresses_valid

    after_create_commit { DeliveryJob.perform_later(self) }

    scope :sent, -> { where(status: "sent") }
    scope :newest_first, -> { order(created_at: :desc, id: :desc) }

    # Records the email and queues it, as whoever is acting (Current.actor). A statement's
    # party may not know its organization, so it can be given.
    def self.request!(subject:, organization: subject.organization, **attributes)
      create!(subject: subject, organization: organization, requested_by: AuditEvent.label_for(Current.actor), **attributes)
    end

    def recipients = to.to_s.split(", ")
    def cc_recipients = cc.to_s.split(", ")
    def sent? = status == "sent"
    def failed? = status == "failed"

    # Another of the same, queued again (after a failure, say).
    def resend!
      self.class.request!(subject: subject, organization: organization, **attributes.symbolize_keys.slice(:kind, :stage, :to, :cc, :subject_line, :message, :details))
    end

    # Sends it, once: the PDF made and the mail delivered, then kept sent; or, when either
    # fails, kept failed with the error. On the audit trail either way.
    def deliver!
      return unless status == "queued"

      pdf, filename = attachment
      TudlaAccounting.configuration.document_mailer.constantize.delivery(self, pdf: pdf, filename: filename).deliver_now
      update!(status: "sent", sent_at: Time.current, error: nil)
      AuditEvent.record!("email.sent", organization: organization, subject: subject, details: { delivery_id: id, kind: kind, to: to, stage: stage }.compact)
    rescue StandardError => e
      update_columns(status: "failed", error: e.message.truncate(1_000), updated_at: Time.current)
      AuditEvent.record!("email.failed", organization: organization, subject: subject, details: { delivery_id: id, kind: kind, to: to, error: error })
    end

    # The PDF to attach and its name, or nil when the engine can't make PDFs.
    def attachment
      return unless TudlaAccounting.pdf?

      case kind
      when "document", "reminder" then [ PdfMaker.document(subject), "#{subject.number_label}.pdf" ]
      when "receipt", "payment_notice" then [ PdfMaker.payment(subject), "#{kind.dasherize}-#{subject.paid_on.iso8601}.pdf" ]
      when "statement" then [ PdfMaker.statements([ statement ], open_items: details["open_items"]), "statement-#{details['thru']}.pdf" ]
      end
    end

    # The statement a statement's email is of, made again from its details (as it stands
    # when it is sent).
    def statement
      PartyStatement.call(organization: organization, type: details.fetch("type").to_sym, party: subject,
                          from: Date.iso8601(details.fetch("from")), thru: Date.iso8601(details.fetch("thru")))
    end

    private

    def addresses_valid
      invalid = (recipients + cc_recipients).grep_v(ADDRESS)
      errors.add(:base, "#{invalid.to_sentence} #{invalid.one? ? "isn't an email address" : "aren't email addresses"}") if invalid.any?
    end
  end
end
