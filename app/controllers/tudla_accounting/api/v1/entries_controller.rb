module TudlaAccounting
  module Api
    module V1
      # Journal entries with their lines: posted or drafts, dated from and to (days the
      # entries are dated, inclusive), touching an account (its code), with a reference,
      # or changed since a time.
      class EntriesController < BaseController
        include Representation

        def index
          entries = organization_scope(Entry).includes(details: [ :account, :tax_code, :foreign_exchange, { tags: %i[dimension dimension_value] } ])
          entries = entries.where.not(posted_at: nil) if params[:status] == "posted"
          entries = entries.where(posted_at: nil) if params[:status] == "draft"
          entries = entries.where(transacted_at: day_start(date_param(:from))..) if params[:from].present?
          entries = entries.where(transacted_at: ...day_start(date_param(:to) + 1)) if params[:to].present?
          entries = entries.where(reference: params[:reference]) if params[:reference].present?
          if params[:account].present?
            account = organization_scope(Account).find_by!(code: params[:account])
            entries = entries.where(id: Detail.where(account_id: account.subtree_ids).select(:entry_id))
          end
          render_page(updated_since(entries).order(:transacted_at, :id)) { |entry| entry_json(entry) }
        end

        def show
          render json: { data: entry_json(organization_scope(Entry).find(params[:id])) }
        end
      end
    end
  end
end
