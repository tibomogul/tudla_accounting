module TudlaAccounting
  module SetupHelper
    # The organization's account with a role, linked, or a warning that none is marked.
    # role_accounts is { role => account } (SetupController#index).
    def role_account_link(role_accounts, role)
      account = role_accounts[role.to_s]
      return tc_badge("none marked", tone: :warning) unless account

      link_to tag.code(account.code_with_name, class: "text-xs"), account_path(account)
    end

    # The forex_rate_provider setting, by class for an object, or a warning when unset.
    def forex_provider_label(config)
      provider = config.forex_rate_provider
      return tc_badge("not set", tone: :warning) unless provider

      tag.code(provider.is_a?(String) ? provider : provider.class.name, class: "text-xs")
    end
  end
end
