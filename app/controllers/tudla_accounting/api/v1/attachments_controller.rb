module TudlaAccounting
  module Api
    module V1
      # The files attached to an entry or a document: uploading them (multipart, as `file`
      # or `files[]`; :record) and downloading one. The record's own JSON lists them. They
      # are checked as on the pages (attachment_content_types, attachment_max_size).
      class AttachmentsController < BaseController
        include Representation
        include ActiveStorage::Streaming

        permits :record, only: :create

        before_action :require_attachments
        before_action :set_record

        def show
          attachment = @record.attachments.find(params[:id])
          send_blob_stream attachment.blob, disposition: :attachment
        end

        def create
          @record.add_attachments!(Array(params[:files]).presence || params[:file])
          render json: { data: attachments_json(@record.reload) }, status: :created
        end

        private

        def require_attachments
          error(:not_found, "This app keeps no attachments (it doesn't load Active Storage)", :not_found) unless TudlaAccounting.attachments?
        end

        def set_record
          @record = params[:document_id] ? organization_scope(Document).find(params[:document_id]) : organization_scope(Entry).find(params[:entry_id])
        end
      end
    end
  end
end
