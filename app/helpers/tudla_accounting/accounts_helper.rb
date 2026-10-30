module TudlaAccounting
  module AccountsHelper
    CATEGORY_LABELS = { "asset" => "Assets", "liability" => "Liabilities", "equity" => "Equity",
                        "income" => "Income", "expense" => "Expenses" }.freeze

    def account_category_options
      Account.categories.keys.map { |category| [ category.capitalize, category ] }
    end

    def account_role_options
      Account::ROLES.map { |role, details| [ details[:name], role ] }
    end

    MISSING_ROLE_EFFECTS = {
      "receivable" => "what customers owe isn't tracked",
      "payable" => "what's owed to suppliers isn't tracked",
      "retained_earnings" => "each year's profit isn't carried into equity",
      "unrealized_fx_gain" => "foreign-currency balances can't be revalued",
      "realized_fx_gain" => "exchange differences on settlement stay on receivables and payables"
    }.freeze

    # What goes unrecorded while no account has these roles (Account.missing_roles).
    def missing_roles_warning(roles)
      names = roles.map { |role| Account.role_name(role).downcase }.to_sentence
      "No account is marked as #{names}: #{MISSING_ROLE_EFFECTS.values_at(*roles).to_sentence}."
    end

    # The organization's accounts as [account, depth] in tree order, sub-accounts under
    # their parent, grouped by category.
    def account_tree_rows(accounts)
      children = accounts.group_by(&:parent_id)
      walk = ->(account, depth) { [ [ account, depth ], *children.fetch(account.id, []).flat_map { |child| walk.call(child, depth + 1) } ] }
      roots = children.fetch(nil, [])
      CATEGORY_LABELS.filter_map do |category, label|
        rows = roots.select { |account| account.category == category }.flat_map { |account| walk.call(account, 0) }
        [ label, category, rows ] if rows.any?
      end
    end

    # Accounts that can be the parent or contra target of this one: the organization's
    # own active ones (and the one chosen already), excluding the account and (for
    # parents) anything beneath it.
    def account_choices(accounts, except: nil, exclude_descendants: false, selected: nil)
      excluded = except ? [ except.id ] : []
      excluded += except.descendant_ids if except&.persisted? && exclude_descendants
      accounts.select { |account| (account.active? || account.id == selected) && excluded.exclude?(account.id) }
              .map { |account| [ account_option_label(account), account.id ] }
    end

    # Accounts a line can be posted to, as choices: the active ones without sub-accounts,
    # and those chosen already (selected: ids), marked when inactive or with sub-accounts.
    def postable_account_choices(accounts, selected: nil)
      chosen = Array(selected).compact.map(&:to_i)
      postable = accounts.postable.pluck(:id).to_set
      accounts.select { |account| (account.active? && postable.include?(account.id)) || chosen.include?(account.id) }
              .map { |account| [ account_option_label(account, parent: postable.exclude?(account.id)), account.id ] }
    end

    # An account as a choice: "6050 - Printing", marked when inactive (or, with parent:,
    # as having sub-accounts).
    def account_option_label(account, parent: false)
      marks = [ ("inactive" unless account.active?), ("has sub-accounts" if parent) ].compact
      marks.empty? ? account.code_with_name : "#{account.code_with_name} (#{marks.join(", ")})"
    end

    # Choices for filtering what's already recorded: every account, inactive ones marked.
    def account_filter_options(accounts)
      accounts.map { |account| [ account_option_label(account), account.id ] }
    end
  end
end
