module TudlaAccounting
  # The attachments of an entry, or of an invoice, bill or credit note, served through the
  # engine so its permissions and organization apply: Active Storage's own routes serve a
  # file to anyone with its signed URL, so the pages never link to them.
  class AttachmentsController < ApplicationController
    include ActiveStorage::Streaming

    permits :record, only: :create

    before_action :require_attachments
    before_action :set_record
    before_action :set_attachment, only: %i[show destroy]
    before_action :authorize_removal, only: :destroy

    def show
      send_blob_stream @attachment.blob, disposition: params[:download] ? :attachment : :inline
    end

    def create
      files = @record.add_attachments!(params[:files])
      redirect_to @back, notice: "#{files.many? ? "#{files.size} files" : files.first.filename} attached."
    rescue ArgumentError => e
      redirect_to @back, alert: "Nothing was attached: #{e.message.downcase_first}."
    end

    def destroy
      @record.remove_attachment!(@attachment, reason: params[:reason])
      redirect_to @back, notice: "#{@attachment.filename} removed."
    rescue ArgumentError => e
      redirect_to @back, alert: "#{e.message}."
    end

    private

    def require_attachments
      raise ActiveRecord::RecordNotFound unless TudlaAccounting.attachments?
    end

    def set_record
      if params[:document_id]
        @record = organization_scope(Document).find(params[:document_id])
        @back = document_path(@record)
      else
        @record = organization_scope(Entry).find(params[:entry_id])
        @back = entry_path(@record)
      end
    end

    def set_attachment
      @attachment = @record.attachments.find(params[:id])
    end

    # A draft's files are part of what is being recorded; a posted entry's (or approved
    # document's) are part of its record, so only those who administer the books take one off.
    def authorize_removal
      permission = @record.attachments_locked? ? :administer : :record
      render "tudla_accounting/shared/not_allowed", status: :forbidden, locals: { permission: permission } unless tc_can?(permission)
    end
  end
end
