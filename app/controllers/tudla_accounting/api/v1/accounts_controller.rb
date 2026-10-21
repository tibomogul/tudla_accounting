module TudlaAccounting
  module Api
    module V1
      # The chart of accounts: by category, active or not, or changed since a time.
      class AccountsController < BaseController
        include Representation

        def index
          accounts = organization_scope(Account).includes(:contra_account).order(:code)
          accounts = accounts.where(category: params[:category]) if params[:category].present?
          accounts = accounts.where(active: ActiveModel::Type::Boolean.new.cast(params[:active])) if params.key?(:active)
          parents = organization_scope(Account).pluck(:id, :code).to_h
          render_page(updated_since(accounts)) { |account| account_json(account).merge(parent_code: parents[account.parent_id]) }
        end

        # By id, or by code ("4000").
        def show
          scope = organization_scope(Account)
          account = params[:id].match?(/\A\d+\z/) && scope.find_by(id: params[:id]) || scope.find_by!(code: params[:id])
          render json: { data: account_json(account) }
        end
      end
    end
  end
end
