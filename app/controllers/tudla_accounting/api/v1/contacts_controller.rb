module TudlaAccounting
  module Api
    module V1
      # Customers and suppliers: by kind, searched (q: name, email or tax number), active
      # or not, or changed since a time.
      # Adding and changing them needs :record.
      class ContactsController < BaseController
        include Representation

        FIELDS = %i[name kind email phone address tax_number payment_terms_days notes active].freeze

        permits :record, only: %i[create update]

        def index
          contacts = organization_scope(Contact).includes(:default_account, :default_tax_code).order(Arel.sql("LOWER(name)"), :id)
          contacts = contacts.public_send(params[:kind].pluralize) if params[:kind].presence_in(%w[customer supplier])
          contacts = contacts.search(params[:q]) if params[:q].present?
          contacts = contacts.where(active: ActiveModel::Type::Boolean.new.cast(params[:active])) if params.key?(:active)
          render_page(updated_since(contacts)) { |contact| contact_json(contact) }
        end

        def show
          render json: { data: contact_json(organization_scope(Contact).find(params[:id])) }
        end

        def create
          contact = organization_scope(Contact).create!(contact_attributes)
          render json: { data: contact_json(contact) }, status: :created
        end

        # Changes only the fields given.
        def update
          contact = organization_scope(Contact).find(params[:id])
          contact.update!(contact_attributes)
          render json: { data: contact_json(contact) }
        end

        private

        def contact_attributes
          attributes = body.slice(*FIELDS)
          attributes[:currency] = body[:currency].to_s if body.key?(:currency) # blank for the organization's own
          attributes[:default_account] = body[:default_account_code].presence && account_by_code(body[:default_account_code], "default_account_code") if body.key?(:default_account_code)
          attributes[:default_tax_code] = body[:default_tax_code].presence && tax_code_by_code(body[:default_tax_code], "default_tax_code") if body.key?(:default_tax_code)
          attributes
        end
      end
    end
  end
end
