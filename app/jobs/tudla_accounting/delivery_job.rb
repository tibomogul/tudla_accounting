# frozen_string_literal: true

module TudlaAccounting
  # Sends a queued email (Delivery#deliver!), as whoever asked for it. A failure is kept
  # on the delivery, to be sent again from the page, so the job itself doesn't retry.
  class DeliveryJob < ApplicationJob
    queue_as :default

    def perform(delivery)
      Current.set(actor: delivery.requested_by) { delivery.deliver! }
    end
  end
end
