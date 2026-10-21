# frozen_string_literal: true

module TudlaAccounting
  # Files attached to a record (receipts on an entry, the supplier's PDF on a bill), when
  # the host app loads Active Storage (see TudlaAccounting.attachments?). add_attachments!
  # and remove_attachment! check them and keep the audit trail, as "<prefix>.attachment_added"
  # and "<prefix>.attachment_removed". Once the record is settled (attachments_locked?: a
  # posted entry, an approved document) its files are part of its record, and taking one
  # off needs a reason.
  module Attachable
    extend ActiveSupport::Concern

    included do
      has_many_attached :attachments if respond_to?(:has_many_attached)
    end

    class_methods do
      # Active Storage's arguments for an uploaded file or a hash of io:, filename: and content_type:.
      def attachable(file)
        return file.slice(:io, :filename, :content_type) if file.is_a?(Hash)

        { io: file, filename: file.original_filename, content_type: file.content_type }
      end
    end

    # Attaches files (uploaded files, or hashes of io:, filename: and content_type:). Each
    # must be of a type in the attachment_content_types setting (as identified from its
    # contents) and no bigger than attachment_max_size; otherwise none is attached.
    def add_attachments!(files)
      raise ArgumentError, "Attachments need Active Storage" unless TudlaAccounting.attachments?

      files = (files.is_a?(Hash) ? [ files ] : Array(files)).compact_blank
      raise ArgumentError, "Choose a file to attach" if files.empty?

      blobs = files.map { |file| ActiveStorage::Blob.create_and_upload!(**self.class.attachable(file)) }
      problems = blobs.filter_map { |blob| attachment_problem(blob) }
      if problems.any?
        blobs.each(&:purge)
        raise ArgumentError, problems.to_sentence
      end

      transaction do
        attachments.attach(blobs) || raise(ActiveRecord::RecordInvalid, self)
        blobs.each { |blob| AuditEvent.record!("#{attachment_event_prefix}.attachment_added", organization: organization, subject: self, details: attachment_details(blob)) }
      end
      blobs
    end

    # Removes one of its attachments: freely before it is settled; afterwards with a reason,
    # kept on the audit trail with the file's name and checksum.
    def remove_attachment!(attachment, reason: nil)
      raise ArgumentError, "That file isn't attached to this #{attachment_event_prefix}" unless attachments.include?(attachment)

      reason = reason.to_s.strip.presence
      raise ArgumentError, "Give a reason for removing a file from #{attachments_locked_label}" if attachments_locked? && reason.nil?

      transaction do
        AuditEvent.record!("#{attachment_event_prefix}.attachment_removed", organization: organization, subject: self,
                           details: attachment_details(attachment.blob).merge(reason ? { reason: reason } : {}))
        attachment.purge
      end
    end

    private

    def attachment_problem(blob)
      config = TudlaAccounting.configuration
      if config.attachment_content_types.exclude?(blob.content_type)
        "#{blob.filename} isn't a kind of file that can be attached (#{blob.content_type})"
      elsif blob.byte_size > config.attachment_max_size
        "#{blob.filename} is bigger than #{ActiveSupport::NumberHelper.number_to_human_size(config.attachment_max_size)}"
      end
    end

    def attachment_details(blob)
      { filename: blob.filename.to_s, content_type: blob.content_type, byte_size: blob.byte_size, checksum: blob.checksum }
    end
  end
end
