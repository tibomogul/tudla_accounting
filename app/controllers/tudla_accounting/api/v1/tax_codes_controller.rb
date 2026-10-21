module TudlaAccounting
  module Api
    module V1
      # The tax codes lines can be taxed under.
      class TaxCodesController < BaseController
        include Representation

        def index
          render_page(organization_scope(TaxCode).includes(:account).order(:code)) { |code| tax_code_json(code) }
        end
      end
    end
  end
end
