# frozen_string_literal: true

module TudlaAccounting
  # Who is acting, for audit events: set from the current_actor setting on each engine
  # page, or by the host around other work:
  #
  #   TudlaAccounting::Current.set(actor: user) { entry.post(Time.current) }
  #
  # And whose books a request is about: set by the engine's pages and API for each
  # request, it limits lookups to that organization (see OrganizationOwned).
  class Current < ActiveSupport::CurrentAttributes
    attribute :actor, :organization
  end
end
