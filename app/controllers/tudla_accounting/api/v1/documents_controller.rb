module TudlaAccounting
  module Api
    module V1
      # Invoices, bills and credit notes with their lines and what is still owed: by kind,
      # status (draft, approved, void), contact, number, issued from and to, or changed
      # since a time.
      class DocumentsController < BaseController
        include Representation

        def index
          documents = organization_scope(Document).includes(:organization, :contact, lines: %i[account tax_code]).order(:issued_on, :id)
          documents = documents.where(kind: params[:kind]) if params[:kind].present?
          documents = documents.where(status: params[:status]) if params[:status].present?
          documents = documents.where(contact_id: params[:contact_id]) if params[:contact_id].present?
          documents = documents.where(number_label: params[:number]) if params[:number].present?
          documents = documents.where(issued_on: date_param(:from)..) if params[:from].present?
          documents = documents.where(issued_on: ..date_param(:to)) if params[:to].present?
          render_page(updated_since(documents), with_page: ->(records) { records.with_open_cents }) { |document| document_json(document) }
        end

        def show
          render json: { data: document_json(organization_scope(Document).with_open_cents.find(params[:id])) }
        end
      end
    end
  end
end
