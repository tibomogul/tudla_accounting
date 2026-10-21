module TudlaAccounting
  # The email of a Delivery: its subject line and message, to and cc whom it says, from
  # and replying to the document_mail_from and document_mail_reply_to settings, with its
  # PDF attached when there is one. A host app's own mailer (the document_mailer setting)
  # takes the same: delivery(delivery, pdf:, filename:), returning a mail to deliver.
  class DocumentMailer < ApplicationMailer
    def delivery(delivery, pdf: nil, filename: nil)
      @delivery = delivery
      settings = TudlaAccounting.configuration
      attachments[filename] = { mime_type: "application/pdf", content: pdf } if pdf
      headers = { to: delivery.recipients, cc: delivery.cc_recipients.presence, subject: delivery.subject_line,
                  from: settings.document_mail_address(:document_mail_from, delivery.organization),
                  reply_to: settings.document_mail_address(:document_mail_reply_to, delivery.organization) }.compact
      mail(headers)
    end
  end
end
