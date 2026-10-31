module TudlaAccounting
  # Payments received from customers and made to suppliers: the lists (with refunds),
  # recording one against a contact's open invoices or bills, refunding what is left of a
  # payment or credit note, and voiding either. See Payment.
  class PaymentsController < ApplicationController
    permits :post, only: %i[new create new_refund create_refund void]

    before_action :set_payment, only: %i[show void]
    include PaymentChoices

    def index
      @kind = kind_param
      payments = organization_scope(Payment).where(kind: Payment.kinds_for(@kind == "received" ? :sales : :purchases)).includes(:contact, :account, entry: { details: :carrying_amount })
      if params[:q].present?
        pattern = "%#{Payment.sanitize_sql_like(params[:q].strip)}%"
        payments = payments.left_joins(:contact).where("tudla_accounting_payments.reference ILIKE :pattern OR tudla_accounting_contacts.name ILIKE :pattern", pattern: pattern)
      end
      payments = payments.where(status: params[:status]) if params[:status].presence_in(%w[posted void])
      payments = payments.order(paid_on: :desc, id: :desc)
      respond_to do |format|
        format.html { @page = Paginator.new(payments, page: params[:page]) }
        format.csv { send_data payments_table(payments).to_csv, filename: "payments-#{@kind}.csv", type: "text/csv" }
      end
    end

    def show
      respond_to do |format|
        format.html { @deliveries = Delivery.where(subject: @payment).newest_first.to_a }
        format.pdf do
          raise ActiveRecord::RecordNotFound if @payment.refund? # a refund has no receipt or notice
          name = "#{@payment.received? ? 'receipt' : 'payment-notice'}-#{@payment.contact.name}-#{@payment.paid_on}"
          send_pdf(name, fallback: payment_path(@payment)) { PdfMaker.payment(@payment) }
        end
      end
    end

    # A payment from (or to) a contact, in a currency (the contact's, when the books can
    # pay in it, or else the organization's, by default), with their open invoices (or
    # bills) in it to apply it to; document_id starts it from one of them, for what is
    # still owed.
    def new
      document = organization_scope(Document).approved.find(params[:document_id]) if params[:document_id].present?
      contact = document&.contact || (organization_scope(Contact).find_by(id: params[:contact_id]) if params[:contact_id].present?)
      @currency = document&.currency || (params[:currency].blank? && contact&.currency.presence_in(payment_currencies)) || currency_param
      @payment = organization_scope(Payment).new(kind: document ? (document.sales? ? "received" : "paid") : kind_param, paid_on: today, contact: contact,
                                                 account_id: default_account_id(@currency))
      @applied = document ? { document.id => document.amount_due.cents } : {}
      @payment.amount_cents = @applied.values.sum if document
      @open = open_documents(@payment, @currency)
    end

    def create
      permitted = params.require(:payment).permit(:kind, :contact_id, :account_id, :paid_on, :amount, :exchange_rate, :reference, :notes, :email_it, applications: {})
      account = organization_scope(Account).find(permitted[:account_id]) if permitted[:account_id].present?
      @currency = account ? account.currency.presence || accounting_organization.currency : currency_param
      problems = []
      cents = ->(text, label) { amount_cents(text, @currency) { |problem| problems << "#{problem} (#{label})" } }
      contact = organization_scope(Contact).find(permitted[:contact_id]) if permitted[:contact_id].present?
      @payment = organization_scope(Payment).new(kind: permitted[:kind].presence_in(%w[received paid]) || "received", contact: contact, paid_on: permitted[:paid_on],
                                                 account_id: account&.id, amount_cents: cents.call(permitted[:amount], "the payment"), reference: permitted[:reference], notes: permitted[:notes],
                                                 exchange_rate: typed_decimal(permitted[:exchange_rate]) { problems << "#{permitted[:exchange_rate]} isn't an exchange rate" })
      @applied = (permitted[:applications]&.to_h || {}).filter_map { |id, text| [ id.to_i, cents.call(text, "applied") ] if text.present? }.to_h.compact
      @open = open_documents(@payment, @currency)
      raise ArgumentError, problems.to_sentence if problems.any?

      documents = organization_scope(Document).where(id: @applied.keys).index_by(&:id)
      applications = @applied.map { |id, applied| { document: documents.fetch(id) { raise ActiveRecord::RecordNotFound }, amount_cents: applied } }
      @payment = Payment.record!(**@payment.attributes.symbolize_keys.slice(:kind, :contact_id, :account_id, :paid_on, :amount_cents, :exchange_rate, :reference, :notes),
                                 organization: accounting_organization, applications: applications)
      redirect_to payment_path(@payment), notice: "#{@payment.title} of #{helpers.tc_money_text(@payment.amount)} recorded.#{email_it(@payment) if permitted[:email_it] == '1'}"
    rescue ArgumentError => e
      @payment.errors.add(:base, e.message)
      render :new, status: :unprocessable_entity
    end

    # Paying back what is left of a payment or credit note (payment_id or document_id), all
    # of it unless less is typed.
    def new_refund
      credit = refund_credit
      left = Payment.credit_left_cents(credit)
      return redirect_to(credit_path(credit), alert: "Nothing is left of it to refund.") unless left.positive?

      @currency = credit.currency
      @payment = organization_scope(Payment).new(kind: credit.sales? ? "refund" : "supplier_refund", contact: credit.contact, paid_on: today,
                                                 account_id: default_account_id(@currency), amount_cents: left)
      @payment.refund_of = credit
    end

    def create_refund
      credit = refund_credit
      @currency = credit.currency
      permitted = params.require(:payment).permit(:account_id, :paid_on, :amount, :exchange_rate, :reference, :notes)
      @payment = organization_scope(Payment).new(kind: credit.sales? ? "refund" : "supplier_refund", contact: credit.contact, paid_on: permitted[:paid_on],
                                                 account_id: (organization_scope(Account).find(permitted[:account_id]).id if permitted[:account_id].present?),
                                                 reference: permitted[:reference], notes: permitted[:notes])
      @payment.refund_of = credit
      @payment.exchange_rate = typed_decimal(permitted[:exchange_rate]) { raise ArgumentError, "#{permitted[:exchange_rate]} isn't an exchange rate" }
      @payment.amount_cents = amount_cents(permitted[:amount], @currency) { |problem| raise ArgumentError, problem }
      @payment = Payment.record!(**@payment.attributes.symbolize_keys.slice(:kind, :contact_id, :account_id, :paid_on, :amount_cents, :exchange_rate, :reference, :notes),
                                 organization: accounting_organization, refund_of: credit)
      redirect_to payment_path(@payment), notice: "#{@payment.title} of #{helpers.tc_money_text(@payment.amount)} recorded."
    rescue ArgumentError => e
      @payment.errors.add(:base, e.message)
      render :new_refund, status: :unprocessable_entity
    end

    def void
      on = Date.iso8601(params[:on].to_s)
      @payment.void!(on: on, reason: params[:reason])
      redirect_to payment_path(@payment), notice: "Payment voided: its entry is reversed on #{helpers.tc_date(on)}."
    rescue ArgumentError => e # an unreadable date too
      redirect_to payment_path(@payment), alert: "It wasn't voided: #{e.message.downcase_first}."
    end

    private

    # Queues its receipt or payment notice, as its template says; what the notice says
    # about it.
    def email_it(payment)
      draft = EmailDraft.for_payment(payment)
      return " It wasn't emailed: #{payment.contact.name} has no email address." if draft[:to].blank?

      Delivery.request!(subject: payment, **draft)
      " Emailing the #{payment.received? ? 'receipt' : 'payment notice'} to #{draft[:to]}."
    end

    def set_payment
      @payment = organization_scope(Payment).includes(:contact, :account).find(params[:id])
    end

    def kind_param = params[:kind].presence_in(%w[received paid]) || "received"

    # The currency asked for, if known; the organization's otherwise.
    def currency_param = Money::Currency.find(params[:currency].to_s)&.iso_code || accounting_organization.currency

    # The credit a refund pays back: a posted payment received or made, or an approved
    # credit note.
    def refund_credit
      if params[:document_id].present?
        organization_scope(Document).approved.where(kind: %w[sales_credit supplier_credit]).find(params[:document_id])
      else
        organization_scope(Payment).where(kind: %w[received paid], status: "posted").find(params.require(:payment_id))
      end
    end

    def credit_path(credit) = credit.is_a?(Document) ? document_path(credit) : payment_path(credit)

    def today
      ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone].today
    end

    # The contact's approved invoices (or bills) in the currency with something still owed,
    # oldest due first.
    def open_documents(payment, currency)
      return [] unless payment.contact

      kind = payment.sales? ? "sales_invoice" : "bill"
      documents = organization_scope(Document).approved.where(kind: kind, contact: payment.contact, currency: (currency unless currency == accounting_organization.currency))
      documents.with_open_cents.order(Arel.sql("due_on ASC NULLS LAST"), :issued_on, :id).to_a.select { |document| document.amount_due.positive? }
    end

    def payments_table(payments)
      rows = payments.map do |payment|
        [ payment.paid_on, payment.contact.name, payment.reference, payment.account.code, payment.amount, payment.unapplied, payment.status, payment.kind_label, payment.currency ]
      end
      Reports::Table.new([ [ "Date", "Contact", "Reference", "Account", "Amount", "Unapplied", "Status", "Kind", "Currency" ], *rows ])
    end
  end
end
