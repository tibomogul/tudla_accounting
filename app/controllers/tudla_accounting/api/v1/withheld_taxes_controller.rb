module TudlaAccounting
  module Api
    module V1
      # Marking the certificate for an amount a customer withheld as received, on a day
      # (on), and unmarking it; both need :post. The amounts are on their payment's JSON.
      class WithheldTaxesController < BaseController
        include Representation

        permits :post, only: %i[mark unmark]

        def mark
          row = organization_scope(WithheldTax).find(params[:id])
          row.mark_certificate!(on: date_param(:on) || raise(ArgumentError, "on is missing"))
          render json: { data: withheld_tax_json(row) }
        end

        def unmark
          row = organization_scope(WithheldTax).find(params[:id])
          row.unmark_certificate!
          render json: { data: withheld_tax_json(row) }
        end
      end
    end
  end
end
