module TudlaAccounting
  module Api
    module V1
      # The supplier pay run (PayRun): show lists the bills it could pay from a bank account
      # (in its currency, due by due_by, one supplier's or all); create (:post) pays a batch
      # of them, one payment per supplier, optionally emailing their payment notices. An
      # Idempotency-Key makes a retried create return the payments the first made.
      class PayRunsController < BaseController
        include Representation

        permits :post, only: :create

        def show
          account = paying_account(params[:account_code])
          contact = organization_scope(Contact).find(params[:contact_id]) if params[:contact_id].present?
          bills = PayRun.due(accounting_organization, currency: currency(account), due_by: date_param(:due_by), contact: contact)
          render json: { data: { account_code: account.code, currency: currency(account), bills: bills.map { |bill| bill_json(bill) } } }
        end

        def create
          existing = made
          return render_run(existing, emailed: emailed(existing)) if existing.any?

          account = paying_account(body[:account_code])
          raise ArgumentError, "bills must be a list" unless body[:bills].is_a?(Array)

          bills = body[:bills].each_with_index.map do |bill, index|
            label = "Bill #{index + 1}"
            raise ArgumentError, "#{label} must be an object with document_id, and amount if not all that is owed" unless bill.is_a?(Hash)

            document = organization_scope(Document).where(kind: "bill").find(bill[:document_id])
            { document: document, amount_cents: bill[:amount].present? ? cents(bill[:amount], "#{label}'s amount", currency: currency(account)) : document.amount_due.cents }
          end
          result = PayRun.call(organization: accounting_organization, account: account, paid_on: date_param(:paid_on) || raise(ArgumentError, "paid_on is missing"),
                               bills: bills, reference: body[:reference], email: boolean(body[:email]),
                               exchange_rate: body[:exchange_rate].presence && decimal(body[:exchange_rate], "exchange_rate"),
                               idempotency_key: (idempotency_key && "#{idempotency_key}:pay_run"))
          render_run(result.payments, emailed: result.emailed, no_address: result.no_address, status: :created)
        rescue ActiveRecord::RecordNotUnique
          existing = made.presence or raise
          render_run(existing, emailed: emailed(existing))
        end

        private

        def paying_account(code) = code.present? ? account_by_code(code, "account_code") : raise(ArgumentError, "account_code is missing")
        def currency(account) = account.currency.presence || accounting_organization.currency

        def bill_json(bill)
          { document_id: bill.id, number: bill.number_label, reference: bill.reference, contact: { id: bill.contact_id, name: bill.contact.name },
            issued_on: date(bill.issued_on), due_on: date(bill.due_on), total: amount(bill.total), amount_due: amount(bill.amount_due) }
        end

        # The payments an earlier run with this Idempotency-Key made (none without one),
        # marked as a replay.
        def made
          key = idempotency_key or return []
          payments = organization_scope(Payment).where("idempotency_key LIKE ?", "#{Payment.sanitize_sql_like(key)}:pay_run:%").order(:id).to_a
          response.headers["Idempotent-Replayed"] = "true" if payments.any?
          payments
        end

        def emailed(payments) = Delivery.where(subject: payments).map(&:subject)

        def render_run(payments, emailed:, no_address: [], status: :ok)
          render json: { data: { payments: payments.map { |payment| payment_json(payment) }, emailed_ids: emailed.map(&:id).uniq, no_address_ids: no_address.map(&:id) } },
                 status: status
        end
      end
    end
  end
end
