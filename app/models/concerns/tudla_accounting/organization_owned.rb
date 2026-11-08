# frozen_string_literal: true

module TudlaAccounting
  # A record in one organization's books. While Current.organization is set, as it is for
  # each request to the engine's pages and API, lookups of these models find only that
  # organization's rows, and new records start in it, so a lookup that misses
  # organization_scope still can't reach another organization's books. Elsewhere (jobs,
  # mailers, the console, a host's own code) it is unset and nothing is filtered: those
  # pass their organization as before. TudlaAccounting.with_organization sets it for a
  # block, and with_organization(nil) lifts it.
  module OrganizationOwned
    extend ActiveSupport::Concern

    included do
      belongs_to :organization, polymorphic: true

      default_scope { (organization = Current.organization) ? where(organization: organization) : all }
    end
  end
end
