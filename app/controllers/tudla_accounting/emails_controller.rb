module TudlaAccounting
  # Emailing an invoice or credit note to its customer: the email to check and change,
  # then queued (see Delivery); and sending one again. Needs :post.
  class EmailsController < ApplicationController
    permits :post, only: %i[new create resend]

    def new
      @document = sendable_document
      @delivery = Delivery.new(subject: @document, organization: accounting_organization, **EmailDraft.for_document(@document))
    end

    def create
      @document = sendable_document
      permitted = params.require(:delivery).permit(:to, :cc, :subject_line, :message)
      @delivery = Delivery.request!(subject: @document, kind: "document", **permitted.to_h.symbolize_keys)
      redirect_to document_path(@document), notice: "Emailing #{@document.title} to #{@delivery.to}."
    rescue ActiveRecord::RecordInvalid => e
      @delivery = e.record
      render :new, status: :unprocessable_entity
    end

    def resend
      delivery = organization_scope(Delivery).find(params[:id])
      again = delivery.resend!
      redirect_to subject_path(delivery.subject), notice: "Emailing it to #{again.to} again."
    end

    private

    # An approved invoice or credit note: what goes to customers.
    def sendable_document
      organization_scope(Document).approved.where(kind: %w[sales_invoice sales_credit]).find(params[:document_id])
    end

    def subject_path(subject)
      case subject
      when Document then document_path(subject)
      end
    end
  end
end
