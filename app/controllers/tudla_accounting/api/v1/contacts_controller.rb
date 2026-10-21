module TudlaAccounting
  module Api
    module V1
      # Customers and suppliers: by kind, searched (q: name, email or tax number), active
      # or not, or changed since a time.
      class ContactsController < BaseController
        include Representation

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
      end
    end
  end
end
