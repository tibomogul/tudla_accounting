# frozen_string_literal: true

module TudlaAccounting
  # One thing done to an organization's books: who (TudlaAccounting::Current.actor, a
  # record or a plain label), what (an action such as "entry.posted"), to what (the
  # subject), and when. Labels are kept with the event so it still reads after the actor
  # or subject is gone. Events are never changed or deleted (on PostgreSQL a trigger
  # enforces it). Once its transaction commits, each is also published as an event; see
  # TudlaAccounting.subscribe.
  class AuditEvent < ApplicationRecord
    ACTIONS = TudlaAccounting::EVENTS

    belongs_to :organization, polymorphic: true
    belongs_to :actor, polymorphic: true, optional: true
    belongs_to :subject, polymorphic: true, optional: true

    validates :action, inclusion: { in: ACTIONS }

    scope :newest_first, -> { order(created_at: :desc, id: :desc) }

    def self.record!(action, organization:, subject: nil, details: {})
      actor = Current.actor
      event = create!(action: action, organization: organization, details: details,
                      actor: (actor unless actor.is_a?(String)), actor_label: label_for(actor),
                      subject: subject, subject_label: label_for(subject))
      ActiveRecord.after_all_transactions_commit do
        ActiveSupport::Notifications.instrument("#{action}.tudla_accounting", event: event)
      end
      event
    end

    def self.label_for(object)
      case object
      when nil, String then object
      when Entry then object.particulars
      when Account then object.code_with_name
      when Period, Allocation, TaxCode then object.label
      else
        %i[name email].each { |method| return object.public_send(method).to_s if object.respond_to?(method) && object.public_send(method).present? }
        "#{object.class.name} ##{object.id}"
      end
    end

    def readonly?
      persisted?
    end
  end
end
