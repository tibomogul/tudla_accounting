module TudlaAccounting
  # Payments received from customers and made to suppliers: the lists, recording one
  # against a contact's open invoices or bills, and voiding it. See Payment.
  class PaymentsController < ApplicationController
    permits :post, only: %i[new create void]

    before_action :set_payment, only: %i[show void]
    helper_method :payment_accounts

    def index
      @kind = kind_param
      payments = organization_scope(Payment).where(kind: @kind).includes(:contact, :account, entry: { details: :carrying_amount })
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
    end

    # A payment from (or to) a contact, with their open invoices (or bills) to apply it to;
    # document_id starts it from one of them, for what is still owed.
    def new
      document = organization_scope(Document).approved.find(params[:document_id]) if params[:document_id].present?
      @payment = organization_scope(Payment).new(kind: document ? (document.sales? ? "received" : "paid") : kind_param, paid_on: today, contact: document&.contact,
                                                 account_id: default_account_id)
      @payment.contact ||= organization_scope(Contact).find_by(id: params[:contact_id]) if params[:contact_id].present?
      @applied = document ? { document.id => document.amount_due.cents } : {}
      @payment.amount_cents = @applied.values.sum if document
      @open = open_documents(@payment)
    end

    def create
      permitted = params.require(:payment).permit(:kind, :contact_id, :account_id, :paid_on, :amount, :reference, :notes, applications: {})
      currency = accounting_organization.currency
      problems = []
      cents = ->(text, label) { amount_cents(text, currency) { problems << "#{text} isn't an amount (#{label})" } }
      contact = organization_scope(Contact).find(permitted[:contact_id]) if permitted[:contact_id].present?
      @payment = organization_scope(Payment).new(kind: permitted[:kind].presence_in(Payment::KINDS.keys) || "received", contact: contact, paid_on: permitted[:paid_on],
                                                 account_id: (organization_scope(Account).find(permitted[:account_id]).id if permitted[:account_id].present?),
                                                 amount_cents: cents.call(permitted[:amount], "the payment"), reference: permitted[:reference], notes: permitted[:notes])
      @applied = permitted.fetch(:applications, {}).to_h.filter_map { |id, text| [ id.to_i, cents.call(text, "applied") ] if text.present? }.to_h.compact
      @open = open_documents(@payment)
      raise ArgumentError, problems.to_sentence if problems.any?

      documents = organization_scope(Document).where(id: @applied.keys).index_by(&:id)
      applications = @applied.map { |id, applied| { document: documents.fetch(id) { raise ActiveRecord::RecordNotFound }, amount_cents: applied } }
      @payment = Payment.record!(**@payment.attributes.symbolize_keys.slice(:kind, :contact_id, :account_id, :paid_on, :amount_cents, :reference, :notes),
                                 organization: accounting_organization, applications: applications)
      redirect_to payment_path(@payment), notice: "#{@payment.title} of #{@payment.amount.format} recorded."
    rescue ArgumentError => e
      @payment.errors.add(:base, e.message)
      render :new, status: :unprocessable_entity
    end

    def void
      on = Date.iso8601(params[:on].to_s)
      @payment.void!(on: on, reason: params[:reason])
      redirect_to payment_path(@payment), notice: "Payment voided: its entry is reversed on #{helpers.tc_date(on)}."
    rescue ArgumentError => e # an unreadable date too
      redirect_to payment_path(@payment), alert: "It wasn't voided: #{e.message.downcase_first}."
    end

    private

    def set_payment
      @payment = organization_scope(Payment).includes(:contact, :account).find(params[:id])
    end

    def kind_param = params[:kind].presence_in(Payment::KINDS.keys) || "received"

    def today
      ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone].today
    end

    # The contact's approved invoices (or bills) with something still owed, oldest due first.
    def open_documents(payment)
      return [] unless payment.contact

      kind = payment.received? ? "sales_invoice" : "bill"
      organization_scope(Document).approved.where(kind: kind, contact: payment.contact).with_open_cents.order(Arel.sql("due_on ASC NULLS LAST"), :issued_on, :id)
        .to_a.select { |document| document.amount_due.positive? }
    end

    # The bank and cash accounts a payment can go through.
    def payment_accounts
      accounts = organization_scope(Account).active.where(category: [ Account::CATEGORY_ASSET, Account::CATEGORY_LIABILITY ], currency: [ nil, accounting_organization.currency ])
      accounts.where(role: nil).or(accounts.where.not(role: %w[receivable payable])).order(:code)
    end

    # The account the last payment went through, or the first cash account.
    def default_account_id
      organization_scope(Payment).order(:id).last&.account_id ||
        organization_scope(Account).where(code: TudlaAccounting.configuration.cash_account_codes_for(accounting_organization)).order(:code).first&.id
    end

    def payments_table(payments)
      rows = payments.map do |payment|
        [ payment.paid_on, payment.contact.name, payment.reference, payment.account.code, payment.amount, payment.unapplied, payment.status ]
      end
      Reports::Table.new([ [ "Date", "Contact", "Reference", "Account", "Amount", "Unapplied", "Status" ], *rows ])
    end
  end
end
