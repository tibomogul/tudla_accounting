# frozen_string_literal: true

module TudlaAccounting
  # A plan for a financial year (period, a year): an amount for each income and expense
  # account in each of the year's months, on the account's own side, as its balances are
  # (income and spending as positive amounts; a contra account's are deducted, as in the
  # statements). Accounts with sub-accounts add theirs up, as balances do, so amounts go
  # on the accounts without sub-accounts.
  #
  # A year can have several budgets, by name; one of them can be its main budget, which
  # the profit and loss compares with unless another is chosen.
  #
  #   budget = Budget.create!(organization: organization, period: year, name: "Original", main: true)
  #   budget.fill_from_actuals!(last_year, percent: 5)
  #   budget.set_amounts!(sales.id => { march.id => 12_000_00 })
  class Budget < ApplicationRecord
    CATEGORIES = [ Account::CATEGORY_INCOME, Account::CATEGORY_EXPENSE ].freeze

    belongs_to :organization, polymorphic: true
    belongs_to :period, class_name: "TudlaAccounting::Period"
    has_many :lines, class_name: "TudlaAccounting::BudgetLine", dependent: :delete_all

    normalizes :name, with: ->(name) { name.strip }

    validates :name, presence: true, uniqueness: { scope: %i[organization_type organization_id period_id] }
    validate :period_is_a_year

    before_save :demote_other_main, if: -> { main? && will_save_change_to_main? }
    after_create { audit("budget.created") }
    after_update { audit("budget.updated", changes: saved_changes.except("created_at", "updated_at")) if saved_changes.except("created_at", "updated_at").any? }
    after_destroy { audit("budget.deleted") }

    scope :newest_first, -> { joins(:period).order("tudla_accounting_periods.from_date DESC", :name) }

    # The accounts a budget can have amounts for.
    def self.accounts(organization)
      Account.where(organization: organization, category: CATEGORIES).order(:code)
    end

    # "Original (2026)".
    def label
      "#{name} (#{period.label})"
    end

    # The year's months (its periods without periods inside them), in order.
    def months
      @months ||= period.subtree.order(:from_date).to_a.select { |month| month.children_count.zero? }
    end

    # { account_id => { period_id => cents } }, the lines there are.
    def amounts
      lines.each_with_object({}) { |line, amounts| (amounts[line.account_id] ||= {})[line.period_id] = line.amount_cents }
    end

    # The budgeted amount of each account and month set in by_account ({ account_id =>
    # { period_id => cents } }); other accounts keep theirs. Raises ArgumentError for an
    # account that isn't the organization's income or expense account, one that is
    # inactive and wasn't in the budget, or a month outside the year.
    def set_amounts!(by_account)
      wanted = by_account.to_h { |account_id, by_month| [ account_id.to_i, by_month.to_h { |month_id, cents| [ month_id.to_i, cents.to_i ] }.reject { |_month, cents| cents.zero? } ] }
      before = amounts
      check_amounts(wanted, before)
      changed = wanted.reject { |account_id, by_month| by_month == before.fetch(account_id, {}) }
      return false if changed.empty?

      transaction do
        lines.where(account_id: changed.keys).delete_all
        rows = changed.flat_map { |account_id, by_month| by_month.map { |month_id, cents| { budget_id: id, account_id: account_id, period_id: month_id, amount_cents: cents } } }
        BudgetLine.insert_all!(rows) if rows.any?
        touch
        audit("budget.updated", accounts: Account.where(id: changed.keys).order(:code).pluck(:code))
      end
      lines.reset
      true
    end

    # The amounts the active accounts had in a year's months (actual, from the balances),
    # month for month (the first month's in the first month), changed by percent and
    # rounded to whole units. An account with sub-accounts takes only what it holds of its
    # own (which only books from before such accounts were refused postings have).
    def fill_from_actuals!(year, percent: 0)
      accounts = self.class.accounts(organization).to_a
      children = accounts.group_by(&:parent_id)
      factor = 1 + BigDecimal(percent.to_s) / 100
      unit = 10**Money::Currency.new(organization.currency).exponent
      wanted = {}
      year_months = year.subtree.order(:from_date).to_a.select { |month| month.children_count.zero? }
      year_months.zip(months).each do |source, month|
        next unless month

        balances = Balance.peek_all(accounts, source)
        accounts.select(&:active?).each do |account|
          own = balances.fetch(account.id).current_amount_cents - children.fetch(account.id, []).sum { |child| balances.fetch(child.id).current_amount_cents }
          cents = (own * factor / unit).round * unit
          (wanted[account.id] ||= {})[month.id] = cents unless cents.zero?
        end
      end
      set_amounts!(wanted)
    end

    # Another budget's amounts, month for month.
    def fill_from_budget!(other)
      month_ids = other.months.map(&:id).zip(months.map(&:id)).to_h
      wanted = other.amounts.transform_values { |by_month| by_month.filter_map { |month_id, cents| [ month_ids[month_id], cents ] if month_ids[month_id] }.to_h }
      set_amounts!(wanted)
    end

    private

    def check_amounts(wanted, before)
      accounts = self.class.accounts(organization).where(id: wanted.keys).index_by(&:id)
      month_ids = months.map(&:id)
      wanted.each do |account_id, by_month|
        account = accounts[account_id] || raise(ArgumentError, "Only the organization's income and expense accounts can have a budget")
        raise ArgumentError, "#{account.code_with_name} is inactive" if !account.active? && by_month.any? && before[account_id].blank?
        raise ArgumentError, "The amounts must be for months of #{period.label}" if (by_month.keys - month_ids).any?
      end
    end

    def period_is_a_year
      return unless period

      errors.add(:period, "must be one of the organization's years") unless period.root? && period.organization == organization
    end

    def demote_other_main
      Budget.where(organization: organization, period_id: period_id, main: true).where.not(id: id).update_all(main: false)
    end

    def audit(action, **details)
      AuditEvent.record!(action, organization: organization, subject: self, details: details)
    end
  end
end
