# frozen_string_literal: true

module TudlaAccounting
  # A token another system uses to reach an organization's books through the JSON API,
  # with the permissions it was given (read, record, post, administer: what the authorize
  # setting checks on the pages). Only a SHA-256 digest of it is kept, so the token itself
  # is seen once, when it is issued:
  #
  #   token, secret = ApiToken.issue!(organization: org, name: "Shop sync", permissions: %w[read record])
  #   ApiToken.authenticate(secret) # => token, while it isn't revoked or expired
  #
  # It acts as itself: what it does is on the audit trail under its name. Revoking it
  # (revoke!) stops it at once; it is never deleted, so its history still reads.
  class ApiToken < ApplicationRecord
    PERMISSIONS = %w[read record post administer].freeze
    PREFIX = "tudla_"
    # How often last_used_at is brought up to date, at most.
    TOUCH_EVERY = 1.minute

    belongs_to :organization, polymorphic: true

    normalizes :name, with: ->(name) { name.squish }
    normalizes :permissions, with: ->(permissions) { PERMISSIONS & Array(permissions).map(&:to_s) }, apply_to_nil: true

    validates :name, presence: true, length: { maximum: 100 }
    validates :token_digest, :hint, presence: true
    validate :permissions_given
    validate :unchanged_but_revoked, on: :update

    before_destroy { throw :abort } # revoke it instead

    scope :active, -> { where(revoked_at: nil).where("expires_on IS NULL OR expires_on >= ?", today) }

    # Makes a token; returns it and its secret, which isn't kept anywhere.
    def self.issue!(organization:, name:, permissions:, expires_on: nil)
      secret = "#{PREFIX}#{SecureRandom.base58(40)}"
      token = create!(organization: organization, name: name, permissions: permissions, expires_on: expires_on,
                      token_digest: digest(secret), hint: secret.first(PREFIX.length + 4), created_by: AuditEvent.label_for(Current.actor))
      AuditEvent.record!("api_token.created", organization: organization, subject: token, details: { permissions: token.permissions, expires_on: token.expires_on&.iso8601 }.compact)
      [ token, secret ]
    end

    # The active token with this secret, its last use noted; nil for anything else.
    def self.authenticate(secret)
      secret = secret.to_s
      return unless secret.start_with?(PREFIX) && secret.length < 200

      token = active.find_by(token_digest: digest(secret))
      token&.touch_last_used
      token
    end

    def self.digest(secret) = OpenSSL::Digest::SHA256.hexdigest(secret)
    def self.today = ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone].today

    def can?(permission) = permissions.include?(permission.to_s)
    def revoked? = revoked_at.present?
    def expired? = expires_on.present? && expires_on < self.class.today
    def active? = !revoked? && !expired?

    # "tudla_Ab3x…"
    def masked = "#{hint}…"

    def revoke!
      raise ArgumentError, "This token is revoked already" if revoked?

      transaction do
        update!(revoked_at: Time.current, revoked_by: AuditEvent.label_for(Current.actor))
        AuditEvent.record!("api_token.revoked", organization: organization, subject: self)
      end
      self
    end

    def touch_last_used
      update_columns(last_used_at: Time.current) if last_used_at.nil? || last_used_at < TOUCH_EVERY.ago
    end

    private

    def permissions_given
      errors.add(:permissions, "choose at least one") if permissions.blank?
    end

    def unchanged_but_revoked
      errors.add(:base, "A token can't be changed; revoke it and issue another") if (changed - %w[revoked_at revoked_by updated_at]).any?
    end
  end
end
