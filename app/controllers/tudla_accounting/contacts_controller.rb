module TudlaAccounting
  # The organization's customers and suppliers: the list (searched, by kind, inactive ones
  # on request, downloadable), each with what they owe or are owed, and adding them one at
  # a time or from a spreadsheet. See Contact.
  class ContactsController < ApplicationController
    permits :record, only: %i[new create edit update destroy import]

    before_action :set_contact, only: %i[show edit update destroy]
    helper_method :contact_accounts, :contact_tax_codes

    def index
      contacts = organization_scope(Contact).order(Arel.sql("LOWER(name)"), :id)
      contacts = contacts.search(params[:q]) if params[:q].present?
      contacts = contacts.public_send(params[:kind].to_s.pluralize) if params[:kind].presence_in(%w[customer supplier])
      contacts = contacts.active unless params[:inactive] == "1"
      respond_to do |format|
        format.html { @page = Paginator.new(contacts.includes(:default_account), page: params[:page]) }
        format.csv { send_data contacts_table(contacts).to_csv, filename: "contacts.csv", type: "text/csv" }
      end
    end

    # The contact, and for each side it is on (customer, supplier) what is open as of
    # today, by how overdue it is.
    def show
      today = Date.current
      @open = @contact.party_types.to_h do |type|
        [ type, AgingReportGenerator.call(organization: accounting_organization, report_type: type, as_of_date: today, party: @contact) ]
      end
    end

    def new
      @contact = organization_scope(Contact).new(kind: params[:kind].presence_in(Contact::KINDS.keys) || "customer")
    end

    def create
      @contact = organization_scope(Contact).new(contact_params)
      if @contact.save
        redirect_to contact_path(@contact), notice: "Contact #{@contact.name} added."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @contact.update(contact_params)
        redirect_to contact_path(@contact), notice: "Contact #{@contact.name} saved."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      if @contact.destroy
        redirect_to contacts_path, notice: "Contact #{@contact.name} deleted."
      else
        redirect_to contact_path(@contact), alert: @contact.errors.full_messages.to_sentence
      end
    end

    # Adds and updates contacts from a CSV or XLSX file; see ContactImporter.
    def import
      file = params.require(:file)
      counts = ContactImporter.call(accounting_organization, file.path, File.extname(file.original_filename).downcase)
      redirect_to contacts_path, notice: "#{helpers.pluralize(counts[:added], 'contact')} added and #{counts[:updated]} updated from #{file.original_filename}."
    rescue ArgumentError, ActionController::ParameterMissing => e
      redirect_to contacts_path, alert: "No contacts were imported: #{e.message.downcase_first}."
    end

    private

    def set_contact
      @contact = organization_scope(Contact).find(params[:id])
    end

    def contact_params
      permitted = params.require(:contact).permit(:name, :kind, :email, :phone, :address, :tax_number, :payment_terms_days, :default_account_id, :default_tax_code_id, :active, :notes)
      permitted[:default_account_id] = organization_scope(Account).find(permitted[:default_account_id]).id if permitted[:default_account_id].present?
      permitted[:default_tax_code_id] = organization_scope(TaxCode).find(permitted[:default_tax_code_id]).id if permitted[:default_tax_code_id].present?
      permitted
    end

    def contacts_table(contacts)
      Reports::Table.new([ [ "Name", "Kind", "Email", "Phone", "Address", "Tax number", "Payment terms", "Default account", "Default tax code", "Active", "Notes" ],
                           *contacts.includes(:default_account, :default_tax_code).map do |contact|
                             [ contact.name, contact.kind, contact.email, contact.phone, contact.address, contact.tax_number, contact.payment_terms_days,
                               contact.default_account&.code, contact.default_tax_code&.code, contact.active? ? "yes" : "no", contact.notes ]
                           end ])
    end

    def contact_accounts
      organization_scope(Account).order(:code)
    end

    def contact_tax_codes
      organization_scope(TaxCode).order(:kind, :code)
    end
  end
end
