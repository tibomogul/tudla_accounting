module TudlaAccounting
  # Base for the engine's pages. Inherits from the host's controller set in the
  # parent_controller setting, so the host's authentication and helpers apply, and shows
  # only the books of the organization the current_organization setting returns.
  class ApplicationController < TudlaAccounting.configuration.parent_controller.constantize
    layout "tudla_accounting/application"

    before_action :require_organization

    rescue_from ActiveRecord::RecordNotFound do
      render "tudla_accounting/shared/not_found", status: :not_found
    end

    helper_method :accounting_organization

    private

    # Named apart from the host's own current_organization, which this class inherits
    # and which the current_organization setting usually calls.
    def accounting_organization
      return @accounting_organization if defined?(@accounting_organization)

      resolver = TudlaAccounting.configuration.current_organization
      raise ConfigurationError, "Set TudlaAccounting.configuration.current_organization to show the books" unless resolver

      @accounting_organization = resolver.call(self)
    end

    def require_organization
      render "tudla_accounting/shared/no_organization", status: :forbidden unless accounting_organization
    end

    # model scoped to the current organization, e.g. organization_scope(Account).find(id)
    def organization_scope(model)
      model.where(organization: accounting_organization)
    end
  end
end
