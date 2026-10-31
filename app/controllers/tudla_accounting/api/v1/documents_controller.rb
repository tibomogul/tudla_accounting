module TudlaAccounting
  module Api
    module V1
      # Invoices, bills and credit notes with their lines and what is still owed: by kind,
      # status (draft, approved, void), contact, number, issued from and to, or changed
      # since a time.
      #
      # Drafting one (create, update; :record) takes its contact, dates and lines; with
      # "approve": true (and :post) it is approved too, all or nothing. An Idempotency-Key
      # makes a retried create return the document the first made. approve and void need
      # :post.
      class DocumentsController < BaseController
        include Representation
        include InvoiceLines

        permits :record, only: %i[create update destroy]
        permits :post, only: %i[approve void]

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

        def create
          existing = replay(organization_scope(Document))
          return render_made(shown(existing)) if existing

          approving = boolean(body[:approve])
          require_permission!(:post) if approving
          kind = body[:kind].to_s.presence_in(Document::KINDS.keys) or raise ArgumentError, "kind must be one of #{Document::KINDS.keys.join(', ')}"
          document = organization_scope(Document).new(kind: kind, idempotency_key: idempotency_key)
          document.assign_attributes(document_attributes(document))
          Document.transaction do
            document.save!
            document.approve! if approving
          end
          render_made(shown(document))
        rescue ActiveRecord::RecordNotUnique
          render_made(shown(replay(organization_scope(Document)) || raise))
        end

        # Changes a draft: the fields given, and with lines, all its lines.
        def update
          document = organization_scope(Document).find(params[:id])
          raise ArgumentError, "Only a draft can be changed; void it and issue another" unless document.draft?

          document.update!(document_attributes(document))
          render json: { data: shown(document) }
        end

        def destroy
          document = organization_scope(Document).find(params[:id])
          document.destroy or raise ArgumentError, document.errors.full_messages.to_sentence
          head :no_content
        end

        def approve
          render json: { data: shown(organization_scope(Document).find(params[:id]).approve!) }
        end

        def void
          document = organization_scope(Document).find(params[:id])
          document.void!(on: date_param(:on) || raise(ArgumentError, "on is missing"), reason: body[:reason])
          render json: { data: shown(document) }
        end

        private

        def shown(document) = document_json(organization_scope(Document).with_open_cents.find(document.id))

        def document_attributes(document)
          attributes = body.slice(:reference, :notes, :tax_inclusive)
          if body.key?(:currency)
            attributes[:currency] = Money::Currency.find(body[:currency].to_s)&.iso_code or raise ArgumentError, "currency must be a currency code, such as \"EUR\""
          end
          attributes[:exchange_rate] = body[:exchange_rate].presence && decimal(body[:exchange_rate], "exchange_rate") if body.key?(:exchange_rate)
          attributes[:contact] = contact_by_id(body[:contact_id]) if body.key?(:contact_id) || document.new_record?
          attributes[:issued_on] = date_param(:issued_on) if body.key?(:issued_on) || document.new_record?
          attributes[:due_on] = date_param(:due_on) if body.key?(:due_on)
          attributes[:due_on] = attributes[:contact].due_on(attributes[:issued_on]) if document.new_record? && !body.key?(:due_on) && attributes[:issued_on]
          if body.key?(:credited_document_id)
            attributes[:credited_document] = body[:credited_document_id].presence && organization_scope(Document).find(body[:credited_document_id])
          end
          # A new one is in its credited document's currency, or its contact's, unless given.
          if document.new_record? && !body.key?(:currency)
            attributes[:currency] = attributes[:credited_document]&.[](:currency) || attributes[:contact]&.[](:currency)
          end
          currency = attributes[:currency] || document.currency
          attributes[:lines_attributes] = document.lines.map { |line| { id: line.id, _destroy: true } } + line_attributes(currency) if body.key?(:lines) || document.new_record?
          attributes
        end
      end
    end
  end
end
