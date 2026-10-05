# frozen_string_literal: true

module TudlaAccounting
  # Posts an entry in the background, into the period of its transacted_at.
  #
  # Entry#post locks the organization, so concurrent posts are safe; with Solid
  # Queue, posting jobs for the same organization also run one at a time rather
  # than waiting on that lock. Failures are logged and the job is discarded
  # without retrying, leaving the entry unposted.
  class EntryPostingJob < ApplicationJob
    queue_as :entry_posting

    limits_concurrency to: 1, key: ->(entry_id) { EntryPostingJob.concurrency_key_for(entry_id) }

    rescue_from(StandardError) do |exception|
      Rails.logger.error("EntryPostingJob failed and will not be retried: #{exception.message}")
    end

    def self.concurrency_key_for(entry_id)
      organization = TudlaAccounting::Entry.where(id: entry_id).pick(:organization_type, :organization_id)
      organization ? organization.join("/") : "unknown"
    end

    def perform(entry_id)
      entry = TudlaAccounting::Entry.find_by(id: entry_id)
      return if entry.nil? || entry.posted_at.present?

      entry.post(entry.transacted_at)
    end
  end
end
