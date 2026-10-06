# frozen_string_literal: true

module TudlaAccounting
  # Who is acting, for audit events: set from the current_actor setting on each engine
  # page, or by the host around other work:
  #
  #   TudlaAccounting::Current.set(actor: user) { entry.post(Time.current) }
  class Current < ActiveSupport::CurrentAttributes
    attribute :actor
  end
end
