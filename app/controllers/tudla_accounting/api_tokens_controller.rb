module TudlaAccounting
  # The organization's API tokens: issuing one (its secret shown once, on the page that
  # follows), listing them with when each was last used, and revoking them. See ApiToken.
  class ApiTokensController < ApplicationController
    permits :administer, only: %i[index new create revoke]

    def index
      @tokens = organization_scope(ApiToken).order(Arel.sql("revoked_at IS NOT NULL"), created_at: :desc)
    end

    def new
      @token = organization_scope(ApiToken).new(permissions: %w[read])
    end

    # Shows the secret on this response only: it isn't kept, and isn't put in the flash
    # (which the session would carry).
    def create
      permitted = params.require(:api_token).permit(:name, :expires_on, permissions: [])
      @token, @secret = ApiToken.issue!(organization: accounting_organization, name: permitted[:name], permissions: permitted[:permissions],
                                        expires_on: permitted[:expires_on].presence)
      response.headers["Cache-Control"] = "no-store"
      render :created, status: :created
    rescue ActiveRecord::RecordInvalid => e
      @token = e.record
      render :new, status: :unprocessable_entity
    end

    def revoke
      token = organization_scope(ApiToken).find(params[:id])
      token.revoke!
      redirect_to api_tokens_path, notice: "#{token.name} revoked: it no longer works."
    rescue ArgumentError => e
      redirect_to api_tokens_path, alert: e.message
    end
  end
end
