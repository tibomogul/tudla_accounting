module TudlaAccounting
  # Recurring invoices: their customers, lines and schedules, making the invoices due now,
  # and a one-off draft from a template. Approving or emailing the invoices it makes needs
  # :post; drafts need :record.
  class RecurringInvoicesController < ApplicationController
    permits :record, only: %i[new create edit update destroy make]
    permits :post, only: :run # a template may approve and email its invoices

    before_action :set_recurring_invoice, only: %i[show edit update destroy make]
    include DocumentChoices

    def index
      @recurring_invoices = organization_scope(RecurringInvoice).includes(:contact, lines: :tax_code).order(:name).to_a
      @today = today
      @due = @recurring_invoices.select { |template| template.due?(@today) }
    end

    def show
      @invoices = @recurring_invoice.invoices.order(issued_on: :desc, id: :desc).with_open_cents.limit(24).to_a
      @dimension_values = DimensionValue.where(id: @recurring_invoice.lines.flat_map(&:dimension_value_ids)).includes(:dimension).index_by(&:id)
    end

    # A new template, or (document_id) one copying an invoice's customer and lines.
    def new
      @recurring_invoice = organization_scope(RecurringInvoice).new(frequency: "monthly", interval: 1, day_of_month: 1, issue: "draft",
                                                                    starts_on: today.next_month.beginning_of_month)
      if params[:document_id].present?
        copy_invoice(organization_scope(Document).where(kind: "sales_invoice").find(params[:document_id]))
      else
        @recurring_invoice.contact = document_contacts(@recurring_invoice).find_by(id: params[:contact_id]) if params[:contact_id].present?
        @recurring_invoice.lines.build(quantity: 1, account: @recurring_invoice.contact&.default_account, tax_code: @recurring_invoice.contact&.default_tax_code)
      end
    end

    def create
      @recurring_invoice = organization_scope(RecurringInvoice).new
      save(:new)
    end

    def edit
    end

    def update
      save(:edit)
    end

    def destroy
      @recurring_invoice.destroy!
      redirect_to recurring_invoices_path, notice: "Recurring invoice #{@recurring_invoice.name} deleted. The invoices made from it stay."
    end

    # Makes the invoices due by today, as the scheduled job would.
    def run
      result = RecurringInvoiceRunner.call(organization: accounting_organization, as_of: today)
      made = result.created.size
      flash[:notice] = if made.zero? then "No invoices were due."
      else
        "Made #{helpers.pluralize(made, 'invoice')}: #{result.approved.size} approved, #{result.emailed.size} emailed."
      end
      flash[:alert] = "Not everything went through: #{result.problems.to_sentence}." if result.problems.any?
      redirect_to recurring_invoices_path
    end

    # A draft invoice for today from the template, apart from its schedule.
    def make
      invoice = @recurring_invoice.build_invoice(on: today)
      invoice.idempotency_key = nil
      invoice.save!
      redirect_to document_path(invoice), notice: "Draft made from #{@recurring_invoice.name}. Approve it, or edit it first."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to recurring_invoice_path(@recurring_invoice), alert: "No draft was made: #{e.record.errors.full_messages.to_sentence.downcase_first}."
    end

    private

    def set_recurring_invoice
      @recurring_invoice = organization_scope(RecurringInvoice).includes(lines: %i[account tax_code]).find(params[:id])
    end

    def today
      ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone].today
    end

    def save(form)
      attributes, problems = template_attributes
      @recurring_invoice.assign_attributes(attributes)
      if @recurring_invoice.approves? && @recurring_invoice.will_save_change_to_issue? && !tc_can?(:post)
        problems << "You can set it up to make drafts, but not to approve or email them"
      end
      if problems.empty? && @recurring_invoice.save
        redirect_to recurring_invoice_path(@recurring_invoice), notice: "Recurring invoice saved. #{next_notice}"
      else
        problems.each { |problem| @recurring_invoice.errors.add(:base, problem) }
        render form, status: :unprocessable_entity
      end
    end

    def next_notice
      @recurring_invoice.next_on ? "The next invoice is due on #{helpers.tc_date(@recurring_invoice.next_on)}." : "Its schedule has run out."
    end

    def copy_invoice(invoice)
      @recurring_invoice.assign_attributes(name: "#{invoice.contact.name} – #{invoice.lines.first&.description}".truncate(60), contact: invoice.contact,
                                           reference: invoice.reference, notes: invoice.notes, tax_inclusive: invoice.tax_inclusive,
                                           due_days: ((invoice.due_on - invoice.issued_on).to_i if invoice.due_on))
      invoice.lines.each do |line|
        @recurring_invoice.lines.build(line.attributes.slice("description", "quantity", "unit_price_cents", "account_id", "tax_code_id", "dimension_value_ids"))
      end
    end

    # The form's fields and lines, each amount read as typed and each account, tax code,
    # dimension value and customer the organization's own; and the amounts that couldn't
    # be read.
    def template_attributes
      permitted = params.require(:recurring_invoice).permit(:name, :contact_id, :reference, :notes, :tax_inclusive, :due_days, :issue, :frequency, :interval,
                                                            :day_of_month, :starts_on, :ends_on, :occurrences_limit, :active,
                                                            lines: [ :id, :description, :quantity, :unit_price, :account_id, :tax_code_id, :_destroy, { dimensions: {} } ])
      currency = accounting_organization.currency
      problems = []
      lines = permitted.delete(:lines).to_h.values.each_with_index.filter_map do |line, index|
        next if line[:id].blank? && line.values_at(:description, :unit_price, :account_id).all?(&:blank?)

        price = amount_cents(line[:unit_price], currency) { |problem| problems << "Line #{index + 1}: #{problem}" }
        { id: line[:id].presence, _destroy: line[:_destroy] }.compact.merge( # a blank tax code clears it
          description: line[:description].to_s,
          quantity: typed_decimal(line[:quantity]) { problems << "Line #{index + 1}: #{line[:quantity]} isn't a quantity" } || 1, position: index,
          unit_price_cents: price.to_i, account_id: (organization_scope(Account).find(line[:account_id]).id if line[:account_id].present?),
          tax_code_id: (organization_scope(TaxCode).find(line[:tax_code_id]).id if line[:tax_code_id].present?), dimension_value_ids: dimension_value_ids(line)
        )
      end
      permitted[:contact_id] = organization_scope(Contact).find(permitted[:contact_id]).id if permitted[:contact_id].present?
      permitted[:day_of_month] = nil if permitted[:day_of_month] == "last"
      [ permitted.merge(lines_attributes: lines), problems ]
    end
  end
end
