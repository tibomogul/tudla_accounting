module TudlaAccounting
  # Base for the engine's pages. Inherits from the host's controller set in the
  # parent_controller setting, so the host's authentication and helpers apply, and shows
  # only the books of the organization the current_organization setting returns.
  class ApplicationController < TudlaAccounting.configuration.parent_controller.constantize
    layout "tudla_accounting/application"
    # Every engine helper in every engine view (the host's helpers come from parent_controller).
    helper TudlaAccounting::ApplicationHelper, TudlaAccounting::AccountsHelper, TudlaAccounting::EntriesHelper, TudlaAccounting::ReportsHelper,
           TudlaAccounting::ActivityHelper

    PERMISSIONS = %i[read record post administer].freeze

    before_action :require_organization
    before_action :set_actor
    before_action :authorize_accounting

    # Which permission each action needs, for the authorize setting: :read unless a
    # controller says otherwise with permits.
    class_attribute :accounting_permissions, default: {}

    def self.permits(permission, only:)
      raise ArgumentError, "unknown permission #{permission.inspect}" unless PERMISSIONS.include?(permission)

      self.accounting_permissions = accounting_permissions.merge(Array(only).to_h { |action| [ action.to_s, permission ] })
    end

    rescue_from ActiveRecord::RecordNotFound do
      render "tudla_accounting/shared/not_found", status: :not_found
    end

    helper_method :accounting_organization, :tc_can?

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

    # Whoever the current_actor setting returns is recorded on audit events.
    def set_actor
      Current.actor = TudlaAccounting.configuration.current_actor&.call(self)
    end

    # Whether the authorize setting lets the current user do what needs permission (one of
    # PERMISSIONS); everything is allowed when it isn't set. Views use it to hide actions.
    def tc_can?(permission)
      hook = TudlaAccounting.configuration.authorize
      return true unless hook

      (@tc_permissions ||= {}).fetch(permission) { @tc_permissions[permission] = hook.call(self, permission) ? true : false }
    end

    def authorize_accounting
      permission = accounting_permissions.fetch(action_name, :read)
      render "tudla_accounting/shared/not_allowed", status: :forbidden, locals: { permission: permission } unless tc_can?(permission)
    end

    # model scoped to the current organization, e.g. organization_scope(Account).find(id)
    def organization_scope(model)
      model.where(organization: accounting_organization)
    end
  end
end
