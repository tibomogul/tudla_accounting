module TudlaAccounting
  module Api
    module V1
      # The withholding codes bills and payments can use.
      class WithholdingCodesController < BaseController
        include Representation

        def index
          render_page(organization_scope(WithholdingCode).includes(:payable_account, :creditable_account).order(:code)) { |code| withholding_code_json(code) }
        end
      end
    end
  end
end
