module TudlaAccounting
  module Api
    module V1
      # The organization the token reaches, and the token itself.
      class OrganizationsController < BaseController
        include Representation

        def show
          render json: { data: organization_json(accounting_organization).merge(token: { name: api_token.name, permissions: api_token.permissions, expires_on: date(api_token.expires_on) }) }
        end
      end
    end
  end
end
