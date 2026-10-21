module TudlaAccounting
  module Api
    module V1
      # Payments received and made, with what each was applied to: by kind, status
      # (posted, void), contact, paid from and to, or changed since a time.
      class PaymentsController < BaseController
        include Representation

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
      end
    end
  end
end
