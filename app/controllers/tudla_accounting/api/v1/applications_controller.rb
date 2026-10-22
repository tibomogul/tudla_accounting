module TudlaAccounting
  module Api
    module V1
      # Applying what is left of a payment or credit note (POST /payments/:id/apply or
      # /documents/:id/apply) to one
      # of the contact's open invoices or bills (document_id in the body), all it can or the
      # amount given, on a day (on; today by default). Needs :post. Answers with the payment
      # or credit note.
      class ApplicationsController < BaseController
        include Representation

        permits :post, only: :create

        def create
          credit = organization_scope(params[:credit] == "payment" ? Payment : Document).find(params[:id])
          raise ArgumentError, "document_id is missing" if body[:document_id].blank?

          target = organization_scope(Document).approved.find(body[:document_id])
          charge = target.entry.details.filter_map(&:carrying_amount).first
          raise ArgumentError, "#{target.title} isn't owed anything it could be applied to" unless credit.entry && Allocator.open_charges(credit.entry).include?(charge)

          day = date_param(:on) || Date.current
          at = ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone].local(day.year, day.month, day.day)
          Allocator.allocate!(credit.entry, charge, at: at, **({ amount_cents: cents(body[:amount], "amount") } if body[:amount].present?).to_h)
          render json: { data: credit.is_a?(Payment) ? payment_json(credit.reload) : document_json(organization_scope(Document).with_open_cents.find(credit.id)) }, status: :created
        end
      end
    end
  end
end
