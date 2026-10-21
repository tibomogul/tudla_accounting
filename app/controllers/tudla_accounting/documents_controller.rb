module TudlaAccounting
  # Sales invoices and credit notes (the sales list), supplier bills and credits (the
  # purchases list): drafting them, approving them (which posts them), voiding them, and
  # each as a page that prints as the document. See Document.
  class DocumentsController < ApplicationController
    permits :record, only: %i[new create edit update destroy]
    permits :post, only: %i[approve void]

    STATUSES = { "draft" => "Draft", "unpaid" => "Awaiting payment", "part_paid" => "Part paid", "overdue" => "Overdue", "paid" => "Paid", "void" => "Void" }.freeze

    before_action :set_document, only: %i[show edit update destroy approve void]
    before_action :require_draft, only: %i[edit update]
    helper_method :side, :document_accounts, :document_tax_codes, :document_contacts

    def index
      documents = filtered(organization_scope(Document).where(kind: Document.kinds_for(side)))
      respond_to do |format|
        format.html do
          @page = Paginator.new(documents, page: params[:page])
          @documents = @page.records.with_open_cents.includes(:contact).to_a
          @reminders_due = ReminderRunner.due(organization: accounting_organization).size if side == "sales"
          @emailed = Delivery.sent.where(subject_type: Document.name, subject_id: @documents.map(&:id)).distinct.pluck(:subject_id).to_set
          open = Document.where(id: documents.approved.select(:id)).with_open_cents
          @due = Money.new(open.sum { |document| document.credit? ? -document.amount_due.cents : document.amount_due.cents }, accounting_organization.currency)
        end
        format.csv { send_data documents_table(documents).to_csv, filename: "#{side}.csv", type: "text/csv" }
      end
    end

    def show
      respond_to do |format|
        format.html do
          @applied = applied(@document)
          @deliveries = Delivery.where(subject: @document).newest_first.to_a
        end
        format.pdf { send_pdf(@document.number_label || "draft-#{@document.kind.dasherize}-#{@document.id}", fallback: document_path(@document)) { PdfMaker.document(@document) } }
      end
    end

    # A new draft of a kind (an invoice by default), for a contact when one is given; or
    # (credit=id) a credit note for an approved invoice or bill, copying its lines.
    def new
      @document = organization_scope(Document).new(kind: params[:kind].presence_in(Document::KINDS.keys) || "sales_invoice", issued_on: today)
      if params[:credit].present?
        credit_for(organization_scope(Document).approved.find(params[:credit]))
      else
        @document.contact = document_contacts(@document).find_by(id: params[:contact_id]) if params[:contact_id].present?
        @document.due_on = @document.contact&.due_on(today)
        @document.lines.build(quantity: 1, account: @document.contact&.default_account, tax_code: @document.contact&.default_tax_code)
      end
    end

    def create
      @document = organization_scope(Document).new
      save_and_maybe_approve(:new)
    end

    def edit
    end

    def update
      save_and_maybe_approve(:edit)
    end

    def destroy
      if @document.destroy
        redirect_to side_path(@document.side), notice: "#{@document.title} to #{@document.contact.name} deleted."
      else
        redirect_to document_path(@document), alert: @document.errors.full_messages.to_sentence
      end
    end

    def approve
      @document.approve!
      redirect_to document_path(@document), notice: "#{@document.title} approved and posted."
    rescue ArgumentError => e
      redirect_to document_path(@document), alert: "It wasn't approved: #{e.message.downcase_first}."
    end

    def void
      on = Date.iso8601(params[:on].to_s)
      @document.void!(on: on, reason: params[:reason])
      redirect_to document_path(@document), notice: "#{@document.title} voided: its entry is reversed on #{helpers.tc_date(on)}."
    rescue ArgumentError => e # an unreadable date too
      redirect_to document_path(@document), alert: "It wasn't voided: #{e.message.downcase_first}."
    end

    private

    def set_document
      @document = organization_scope(Document).includes(lines: %i[account tax_code]).find(params[:id])
    end

    def require_draft
      redirect_to document_path(@document), alert: "An approved document can't be changed; void it and issue another." unless @document.draft?
    end

    def side
      @side ||= @document&.kind ? @document.side.to_s : params[:side].presence_in(%w[sales purchases]) || "sales"
    end

    def side_path(side) = side.to_s == "sales" ? sales_documents_path : purchase_documents_path

    def today
      ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone].today
    end

    # The list narrowed to a kind, how it stands, a contact, and a number, reference or name.
    def filtered(documents)
      documents = documents.where(kind: params[:kind]) if params[:kind].presence_in(Document.kinds_for(side))
      documents = documents.where(contact_id: params[:contact_id]) if params[:contact_id].present?
      if params[:q].present?
        pattern = "%#{Document.sanitize_sql_like(params[:q].strip)}%"
        documents = documents.left_joins(:contact).where("tudla_accounting_documents.number_label ILIKE :pattern OR tudla_accounting_documents.reference ILIKE :pattern " \
                                                         "OR tudla_accounting_contacts.name ILIKE :pattern", pattern: pattern)
      end
      documents = by_status(documents, params[:status]) if params[:status].presence_in(STATUSES.keys)
      documents.order(issued_on: :desc, id: :desc)
    end

    def by_status(documents, status)
      return documents.where(status: status) if %w[draft void].include?(status)

      open = Document.with_open_cents.where(id: documents.approved.select(:id))
      ids = Document.from(open, :tudla_accounting_documents)
      ids = case status
      when "unpaid" then ids.where("open_cents = total_cents")
      when "part_paid" then ids.where("open_cents > 0 AND open_cents < total_cents")
      when "paid" then ids.where("open_cents = 0")
      else ids.where("open_cents > 0 AND due_on < ?", today)
      end
      documents.where(id: ids.select(:id))
    end

    # Saves the form, then with "Approve" pressed (and the :post permission) approves it;
    # if that fails, the draft stays saved.
    def save_and_maybe_approve(form)
      attributes, problems = document_attributes
      @document.assign_attributes(attributes)
      approving = params[:approve].present?
      return refuse_approval(form) if approving && !tc_can?(:post)

      saved = problems.empty? && @document.save && (!approving || approve_saved)
      if saved
        redirect_to document_path(@document), notice: approving ? "#{@document.title} approved and posted." : "#{@document.title} saved."
      else
        problems.each { |problem| @document.errors.add(:base, problem) }
        render form, status: :unprocessable_entity
      end
    end

    def approve_saved
      @document.approve!
      true
    rescue ArgumentError => e
      @document.errors.add(:base, "It was saved as a draft but not approved: #{e.message.downcase_first}")
      false
    end

    def refuse_approval(form)
      @document.errors.add(:base, "You can save drafts but not approve them")
      render form, status: :forbidden
    end

    # The form's fields and lines, each amount read as typed and each account, tax code,
    # contact and credited document the organization's own; and the amounts that couldn't
    # be read.
    def document_attributes
      permitted = params.require(:document).permit(:kind, :contact_id, :reference, :issued_on, :due_on, :tax_inclusive, :notes, :credited_document_id,
                                                   lines: %i[id description quantity unit_price account_id tax_code_id _destroy])
      permitted.delete(:kind) if @document.persisted?
      currency = accounting_organization.currency
      problems = []
      lines = permitted.delete(:lines).to_h.values.each_with_index.filter_map do |line, index|
        next if line[:id].blank? && line.values_at(:description, :unit_price, :account_id).all?(&:blank?)

        price = amount_cents(line[:unit_price], currency) { problems << "Line #{index + 1}: #{line[:unit_price]} isn't an amount" }
        { id: line[:id].presence, _destroy: line[:_destroy], description: line[:description].to_s, quantity: line[:quantity].presence || 1,
          unit_price_cents: price.to_i, account_id: (organization_scope(Account).find(line[:account_id]).id if line[:account_id].present?),
          tax_code_id: (organization_scope(TaxCode).find(line[:tax_code_id]).id if line[:tax_code_id].present?) }.compact
      end
      permitted[:contact_id] = organization_scope(Contact).find(permitted[:contact_id]).id if permitted[:contact_id].present?
      permitted[:credited_document_id] = organization_scope(Document).find(permitted[:credited_document_id]).id if permitted[:credited_document_id].present?
      [ permitted.merge(lines_attributes: lines), problems ]
    end

    def credit_for(original)
      @document.assign_attributes(kind: original.sales? ? "sales_credit" : "supplier_credit", contact: original.contact, credited_document: original,
                                  tax_inclusive: original.tax_inclusive, reference: original.number_label)
      original.lines.each do |line|
        @document.lines.build(line.attributes.slice("description", "quantity", "unit_price_cents", "account_id", "tax_code_id"))
      end
    end

    # The payments and credit notes applied to an invoice or bill, or the invoices and
    # bills a credit note was applied to: [entry, amount, allocated_at, reversed?].
    def applied(document)
      carrying_amount = document.entry&.details&.filter_map(&:carrying_amount)&.first
      return [] unless carrying_amount

      carrying_amount.allocations.includes(from: { detail: :entry }, to: { detail: :entry }).order(:allocated_at, :id).map do |allocation|
        other = carrying_amount.credit? ? allocation.to : allocation.from
        { entry: other.detail.entry, amount: Money.new(allocation.amount_cents, accounting_organization.currency), on: allocation.allocated_at, reversed: allocation.reversed_at.present? }
      end
    end

    def document_contacts(document)
      contacts = organization_scope(Contact).order(Arel.sql("LOWER(name)"))
      contacts = document.sales? ? contacts.customers : contacts.suppliers
      contacts.active.or(contacts.where(id: document.contact_id))
    end

    # Active accounts other than receivables and payables, and any the lines have already.
    def document_accounts(document)
      used = document.lines.filter_map(&:account_id)
      accounts = organization_scope(Account).where(role: nil).or(organization_scope(Account).where.not(role: %w[receivable payable]))
      accounts.active.or(organization_scope(Account).where(id: used)).order(:code)
    end

    # The side's active tax codes, and any the lines have already.
    def document_tax_codes(document)
      used = document.lines.filter_map(&:tax_code_id)
      codes = organization_scope(TaxCode).where(kind: document.sales? ? :sales : :purchases)
      codes.active.or(codes.where(id: used)).order(:code)
    end

    def documents_table(documents)
      rows = Document.with_open_cents.where(id: documents.select(:id)).includes(:contact).order(issued_on: :desc, id: :desc).map do |document|
        [ document.kind_label, document.number_label, document.issued_on, document.contact.name, document.reference, document.due_on,
          document.subtotal, document.tax, document.total, document.amount_due, STATUSES.fetch(document.payment_status, document.payment_status.humanize) ]
      end
      Reports::Table.new([ [ "Kind", "Number", "Date", "Contact", "Reference", "Due", "Subtotal", "Tax", "Total", "Due now", "Status" ], *rows ])
    end
  end
end
