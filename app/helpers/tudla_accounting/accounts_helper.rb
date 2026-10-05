module TudlaAccounting
  module AccountsHelper
    CATEGORY_LABELS = { "asset" => "Assets", "liability" => "Liabilities", "equity" => "Equity",
                        "income" => "Income", "expense" => "Expenses" }.freeze

    def account_category_options
      Account.categories.keys.map { |category| [ category.capitalize, category ] }
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
    # own, excluding the account and (for parents) anything beneath it.
    def account_choices(accounts, except: nil, exclude_descendants: false)
      excluded = except ? [ except.id ] : []
      excluded += except.descendant_ids if except&.persisted? && exclude_descendants
      accounts.reject { |account| excluded.include?(account.id) }.map { |account| [ account.code_with_name, account.id ] }
    end
  end
end
