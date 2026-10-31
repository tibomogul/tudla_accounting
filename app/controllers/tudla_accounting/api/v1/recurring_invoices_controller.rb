module TudlaAccounting
  module Api
    module V1
      # Recurring invoices: the templates, with their customer, lines and schedule; by
      # contact, active or not, or changed since a time.
      #
      # Setting one up or changing it (create, update; :record) takes its fields and, with
      # lines, all its lines; one that approves or emails its invoices needs :post to be set
      # so. run (:post) makes the invoices due by today, as the scheduled job would; make
      # (:record) a draft from one for a date (today by default), apart from its schedule,
      # once per Idempotency-Key.
      class RecurringInvoicesController < BaseController
        include Representation
        include InvoiceLines

        FIELDS = %i[name reference notes tax_inclusive due_days issue frequency interval starts_on ends_on occurrences_limit active].freeze

        permits :record, only: %i[create update destroy make]
        permits :post, only: :run

        def index
          templates = organization_scope(RecurringInvoice).includes(:organization, :contact, lines: %i[account tax_code]).order(:name, :id)
          templates = templates.where(contact_id: params[:contact_id]) if params[:contact_id].present?
          templates = templates.where(active: boolean(params[:active])) if params.key?(:active)
          render_page(updated_since(templates)) { |template| recurring_invoice_json(template) }
        end

        def show
          render json: { data: recurring_invoice_json(template) }
        end

        def create
          save(organization_scope(RecurringInvoice).new, :created)
        end

        # Changes the fields given, and with lines, all its lines.
        def update
          save(template, :ok)
        end

        # The invoices made from it stay.
        def destroy
          template.destroy!
          head :no_content
        end

        def run
          result = RecurringInvoiceRunner.call(organization: accounting_organization, as_of: today)
          invoices = organization_scope(Document).with_open_cents.includes(:contact, lines: %i[account tax_code]).where(id: result.created.map(&:id)).order(:issued_on, :id)
          render json: { data: { invoices: invoices.map { |invoice| document_json(invoice) }, emailed_ids: result.emailed.map(&:id), problems: result.problems } }
        end

        def make
          existing = replay(organization_scope(Document))
          return render_made(shown(existing)) if existing

          invoice = template.build_invoice(on: date_param(:on) || today)
          invoice.idempotency_key = idempotency_key
          invoice.save!
          render_made(shown(invoice))
        rescue ActiveRecord::RecordNotUnique
          render_made(shown(replay(organization_scope(Document)) || raise))
        end

        private

        def template
          @template ||= organization_scope(RecurringInvoice).includes(lines: %i[account tax_code]).find(params[:id])
        end

        def save(template, status)
          template.assign_attributes(template_attributes(template))
          require_permission!(:post) if template.approves? && template.will_save_change_to_issue?
          template.save!
          render json: { data: recurring_invoice_json(template.reload) }, status: status
        end

        def template_attributes(template)
          attributes = body.slice(*FIELDS)
          attributes[:contact] = contact_by_id(body[:contact_id]) if body.key?(:contact_id) || template.new_record?
          attributes[:day_of_month] = (body[:day_of_month] unless body[:day_of_month] == "last") if body.key?(:day_of_month) # null or "last": the month's last day
          if body.key?(:lines) || template.new_record?
            lines = line_attributes(accounting_organization.currency).each_with_index.map { |line, index| line.merge(position: index) }
            attributes[:lines_attributes] = template.lines.map { |line| { id: line.id, _destroy: true } } + lines
          end
          attributes
        end

        def shown(invoice) = document_json(organization_scope(Document).with_open_cents.find(invoice.id))
      end
    end
  end
end
