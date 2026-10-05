module TudlaAccounting
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    private

    # Posting reads balances and writes them back, so posts for the same
    # organization must not interleave. Locking the organization's row
    # (SELECT ... FOR UPDATE) for the rest of the current transaction makes
    # concurrent posts for one organization take turns; other organizations are
    # unaffected. Call it inside a transaction; re-locking within the same
    # transaction is a no-op.
    def lock_organization!
      organization.class.lock.find(organization.id)
    end
  end
end
