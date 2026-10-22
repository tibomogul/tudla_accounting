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
          Allocator.allocate!(credit.entry, charge, at: at, **amount_given(charge))
          render json: { data: credit.is_a?(Payment) ? payment_json(credit.reload) : document_json(organization_scope(Document).with_open_cents.find(credit.id)) }, status: :created
        end

        private

        # The amount given, if any: in the charge's currency when it is foreign (the credit's
        # being the same), else the organization's.
        def amount_given(charge)
          return {} if body[:amount].blank?
          return { other_currency_cents: cents(body[:amount], "amount", currency: charge.forex.other_currency) } if charge.forex

          { amount_cents: cents(body[:amount], "amount") }
        end
      end
    end
  end
end
