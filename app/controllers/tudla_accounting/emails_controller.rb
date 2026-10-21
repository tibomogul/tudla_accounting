module TudlaAccounting
  # Emailing to customers and suppliers (see Delivery): an invoice or credit note
  # (document_id; with reminder, a reminder of an overdue invoice), a payment's receipt or payment notice (payment_id), or a statement of
  # account (type, party, from, thru and show, as the statement page has them). The email
  # is shown to check and change, then queued. Also every statement with something to
  # send at once, and sending one again. Needs :post.
  class EmailsController < ApplicationController
    permits :post, only: %i[new create statements resend]

    before_action :load_target, only: %i[new create]

    def new
      @delivery = Delivery.new(subject: @subject, organization: accounting_organization, **@draft)
    end

    def create
      permitted = params.require(:delivery).permit(:to, :cc, :subject_line, :message)
      @delivery = Delivery.request!(subject: @subject, organization: accounting_organization, kind: @draft[:kind], details: @draft.fetch(:details, {}),
                                    stage: @draft[:stage], **permitted.to_h.symbolize_keys)
      redirect_to @back, notice: "Emailing #{@title} to #{@delivery.to}."
    rescue ActiveRecord::RecordInvalid => e
      @delivery = e.record
      render :new, status: :unprocessable_entity
    end

    # Each statement the statements page lists, to its customer or supplier, as its
    # template says; those without an email address are named, and left out.
    def statements
      type, from, thru, open_items = statement_params
      no_address = []
      count = 0
      PartyStatement.to_send(accounting_organization, type: type, from: from, thru: thru, open_items: open_items).each do |statement|
        draft = EmailDraft.for_statement(statement, open_items: open_items)
        if draft[:to].blank?
          no_address << PartyStatement.party_name(statement.party)
        else
          Delivery.request!(subject: statement.party, organization: accounting_organization, **draft)
          count += 1
        end
      end
      flash[:notice] = count.positive? ? "Emailing #{helpers.pluralize(count, 'statement')}." : ("No statements to email." if no_address.empty?)
      flash[:alert] = ("Not emailed, as they have no email address: #{no_address.to_sentence}." if no_address.any?)
      redirect_to reports_statements_path(type: type, from: from, thru: thru, show: (open_items ? "open_items" : nil))
    end

    def resend
      delivery = organization_scope(Delivery).find(params[:id])
      again = delivery.resend!
      redirect_to back_path(delivery), notice: "Emailing it to #{again.to} again."
    end

    private

    # What is emailed: @subject, @draft, @title (for the page and notice), @recipient (their
    # name), @back (where to go after), @attachment (the PDF's name) and @target (the
    # parameters naming it).
    def load_target
      if params[:document_id].present? then document_target
      elsif params[:payment_id].present? then payment_target
      else statement_target
      end
    end

    # An approved invoice or credit note: what goes to customers. Or a reminder of an
    # invoice past its due date with something still owing, for the reminder day it has
    # reached (if any).
    def document_target
      @subject = organization_scope(Document).approved.where(kind: %w[sales_invoice sales_credit]).find(params[:document_id])
      @recipient = @subject.contact.name
      @back = document_path(@subject)
      @attachment = "#{@subject.number_label}.pdf"
      if params[:reminder].present?
        raise ActiveRecord::RecordNotFound unless @subject.overdue?(today)

        days = TudlaAccounting.configuration.reminder_days.select { |day| day <= (today - @subject.due_on).to_i }.max
        @draft = EmailDraft.for_reminder(@subject, days: days)
        @title = "a reminder of #{@subject.title.downcase_first}"
        @target = { document_id: @subject.id, reminder: 1 }
      else
        @draft = EmailDraft.for_document(@subject)
        @title = @subject.title.downcase_first
        @target = { document_id: @subject.id }
      end
    end

    def today
      ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone].today
    end

    def payment_target
      @subject = organization_scope(Payment).where(status: "posted").find(params[:payment_id])
      @draft = EmailDraft.for_payment(@subject)
      @recipient = @subject.contact.name
      @title = "the #{@subject.received? ? 'receipt' : 'payment notice'} for the #{@subject.title.downcase_first}"
      @back = payment_path(@subject)
      @attachment = "#{@draft[:kind].dasherize}-#{@subject.paid_on.iso8601}.pdf"
      @target = { payment_id: @subject.id }
    end

    # One of the parties with receivables (or payables), over the days given.
    def statement_target
      type, from, thru, open_items = statement_params
      @subject = PartyStatement.parties(accounting_organization, type).find { |party| PartyStatement.key(party) == params[:party] } or raise ActiveRecord::RecordNotFound
      statement = PartyStatement.call(organization: accounting_organization, type: type, party: @subject, from: from, thru: thru)
      @draft = EmailDraft.for_statement(statement, open_items: open_items)
      @recipient = PartyStatement.party_name(@subject)
      @title = "#{@recipient}'s statement"
      @target = { type: type, party: params[:party], from: from, thru: thru, show: (open_items ? "open_items" : nil) }.compact
      @back = reports_statement_path(@target)
      @attachment = "statement-#{thru.iso8601}.pdf"
    end

    def statement_params
      type = params[:type].presence_in(%w[receivable payable]) or raise ActiveRecord::RecordNotFound
      from, thru = %i[from thru].map { |name| Date.iso8601(params.require(name)) }
      [ type.to_sym, *[ from, thru ].minmax, params[:show] == "open_items" ]
    rescue Date::Error
      raise ActiveRecord::RecordNotFound
    end

    # The page of what an email was of.
    def back_path(delivery)
      case delivery.subject
      when Document then document_path(delivery.subject)
      when Payment then payment_path(delivery.subject)
      else
        details = delivery.details
        reports_statement_path(type: details["type"], party: PartyStatement.key(delivery.subject), from: details["from"], thru: details["thru"],
                               show: (details["open_items"] ? "open_items" : nil))
      end
    end
  end
end
