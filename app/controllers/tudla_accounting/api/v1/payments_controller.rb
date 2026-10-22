module TudlaAccounting
  module Api
    module V1
      # Payments received and made, with what each was applied to: by kind, status
      # (posted, void), contact, paid from and to, or changed since a time.
      #
      # Recording one (create) and voiding it need :post. An Idempotency-Key makes a
      # retried create return the payment the first recorded. A refund (kind refund or
      # supplier_refund) names the credit it pays back: refund_of { payment_id } or
      # { document_id } (a credit note).
      class PaymentsController < BaseController
        include Representation

        permits :post, only: %i[create void]

        def index
          payments = organization_scope(Payment).includes(:organization, :contact, :account, entry: { details: :carrying_amount }).order(:paid_on, :id)
          payments = payments.where(kind: params[:kind]) if params[:kind].present?
          payments = payments.where(status: params[:status]) if params[:status].present?
          payments = payments.where(contact_id: params[:contact_id]) if params[:contact_id].present?
          payments = payments.where(paid_on: date_param(:from)..) if params[:from].present?
          payments = payments.where(paid_on: ..date_param(:to)) if params[:to].present?
          render_page(updated_since(payments)) { |payment| payment_json(payment) }
        end

        def show
          render json: { data: payment_json(organization_scope(Payment).find(params[:id])) }
        end

        def create
          existing = replay(organization_scope(Payment))
          return render_made(payment_json(existing)) if existing

          account = account_by_code(body[:account_code], "account_code")
          currency = account.currency.presence || accounting_organization.currency # amounts are in the account's
          applications = Array.wrap(body[:applications]).each_with_index.map do |application, index|
            raise ArgumentError, "Application #{index + 1} must be an object with document_id and amount" unless application.is_a?(Hash)

            { document: organization_scope(Document).find(application[:document_id]), amount_cents: cents(application[:amount], "Application #{index + 1}'s amount", currency: currency) }
          end
          payment = Payment.record!(organization: accounting_organization, kind: body[:kind].to_s, contact: contact_by_id(body[:contact_id]),
                                    account: account, paid_on: date_param(:paid_on) || raise(ArgumentError, "paid_on is missing"),
                                    amount_cents: cents(body[:amount], "amount", currency: currency), reference: body[:reference], notes: body[:notes],
                                    exchange_rate: body[:exchange_rate].presence && decimal(body[:exchange_rate], "exchange_rate"),
                                    idempotency_key: idempotency_key, applications: applications, refund_of: refund_of)
          render_made(payment_json(payment))
        rescue ActiveRecord::RecordNotUnique
          render_made(payment_json(replay(organization_scope(Payment)) || raise))
        end

        def void
          payment = organization_scope(Payment).find(params[:id])
          payment.void!(on: date_param(:on) || raise(ArgumentError, "on is missing"), reason: body[:reason])
          render json: { data: payment_json(payment.reload) }
        end

        private

        def refund_of
          given = body[:refund_of]
          return if given.blank?
          raise ArgumentError, "refund_of must be an object with payment_id or document_id" unless given.is_a?(Hash) && (given[:payment_id].present? ^ given[:document_id].present?)

          given[:payment_id].present? ? organization_scope(Payment).find(given[:payment_id]) : organization_scope(Document).find(given[:document_id])
        end
      end
    end
  end
end
