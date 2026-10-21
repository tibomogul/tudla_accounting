# frozen_string_literal: true

module TudlaAccounting
  class Account < ApplicationRecord
    belongs_to :organization, polymorphic: true
    has_ancestry orphan_strategy: :restrict, cache_depth: true, ancestry_format: :materialized_path2

    CATEGORY_ASSET = "asset".freeze
    CATEGORY_LIABILITY = "liability".freeze
    CATEGORY_EQUITY = "equity".freeze
    CATEGORY_INCOME = "income".freeze
    CATEGORY_EXPENSE = "expense".freeze

    enum :category, {
      CATEGORY_ASSET.to_sym => 0,
      CATEGORY_LIABILITY.to_sym => 1,
      CATEGORY_EQUITY.to_sym => 2,
      CATEGORY_INCOME.to_sym => 3,
      CATEGORY_EXPENSE.to_sym => 4
    }

    # The accounts the engine treats specially, at most one of each per organization:
    # what customers owe (receivable) and what's owed to suppliers (payable), each with
    # the accounts beneath it; where each year's profit is carried (retained_earnings);
    # and where exchange differences go, on revaluation (unrealized_fx_gain) and on
    # settlement (realized_fx_gain). Marking the account, rather than naming its code in
    # the settings, lets each organization's chart differ and its codes be renumbered.
    # The database checks the role too: a new one also needs a migration replacing the
    # tudla_accounting_accounts_role_known check constraint. Roles change only through
    # AccountRoleAssigner, which checks what a change would disturb.
    ROLES = {
      "receivable" => { name: "Receivables", categories: %w[asset], needs: "an asset account" },
      "payable" => { name: "Payables", categories: %w[liability], needs: "a liability account" },
      "retained_earnings" => { name: "Retained earnings", categories: %w[equity], needs: "an equity account" },
      "unrealized_fx_gain" => { name: "Unrealized exchange gains and losses", categories: %w[income expense], needs: "an income or expense account" },
      "realized_fx_gain" => { name: "Realized exchange gains and losses", categories: %w[income expense], needs: "an income or expense account" }
    }.freeze

    enum :role, ROLES.keys.index_with(&:itself), prefix: true, validate: { allow_nil: true }

    # The organization's account with a role, if it has one.
    def self.for_role(organization, role)
      find_by(organization: organization, role: role.to_s)
    end

    # The organization's account with a role; ArgumentError when it has none.
    def self.for_role!(organization, role)
      for_role(organization, role) or raise ArgumentError, missing_role_message(organization, role)
    end

    def self.missing_role_message(organization, role)
      "No account is marked as the #{role_name(role)} account for #{TudlaAccounting.organization_label(organization)}; mark one in the chart of accounts"
    end

    def self.role_name(role) = ROLES.fetch(role.to_s)[:name]

    # The roles most books need, which nothing raises about when no account has them:
    # without them receivables and payables go untracked and no profit is carried.
    EXPECTED_ROLES = %w[receivable payable retained_earnings].freeze

    # The roles books holding foreign currency need: without them revaluation raises, and
    # exchange differences on settlement quietly stay on the receivable or payable account.
    FOREIGN_CURRENCY_ROLES = %w[unrealized_fx_gain realized_fx_gain].freeze

    # The carrying_amount_sources roles that open or settle what's owed on each side:
    # receivables and payables are only expected when some source records them.
    TRACKED_BY = {
      "receivable" => %i[receivable receipt credit_note refund],
      "payable" => %i[payable disbursement supplier_credit supplier_refund]
    }.freeze

    # The expected roles no account of the organization's has: EXPECTED_ROLES, and
    # FOREIGN_CURRENCY_ROLES once an account is held in another currency.
    def self.missing_roles(organization)
      sources = TudlaAccounting.configuration.carrying_amount_sources.values
      expected = EXPECTED_ROLES.select { |role| !TRACKED_BY.key?(role) || TRACKED_BY[role].intersect?(sources) }
      expected += FOREIGN_CURRENCY_ROLES if foreign_currency?(organization)
      expected - where(organization: organization, role: expected).pluck(:role)
    end

    # Whether one of the organization's accounts is held in a currency other than its own.
    def self.foreign_currency?(organization)
      where(organization: organization).where.not(currency: [ nil, organization.currency ]).exists?
    end

    normalizes :currency, with: ->(currency) { currency.strip.upcase.presence }
    normalizes :role, with: ->(role) { role.to_s.strip.presence }

    validates :name, :code, :category, presence: true
    validates :code, uniqueness: { scope: [ :organization_type, :organization_id ] }

    validate :validate_parent
    validate :validate_known_currency
    validate :validate_structure_unchanged_once_used, on: :update
    validate :validate_category_unchanged_in_budgets, on: :update
    validate :validate_role_category
    validate :validate_role_assigned
    validate :validate_active_parent
    validate :validate_role_active
    validate :validate_deactivation, if: -> { will_save_change_to_active?(to: false) }

    # Accounts offered for new entries; inactive ones keep their history.
    scope :active, -> { where(active: true) }

    before_destroy :ensure_deletable, prepend: true
    after_create { audit("account.created") }
    after_update { audit("account.updated", changes: saved_changes.except("created_at", "updated_at")) if !@changing_active && saved_changes.except("created_at", "updated_at").any? }
    after_destroy { audit("account.deleted") }

    has_many :balances, dependent: :destroy, class_name: "TudlaAccounting::Balance"
    has_many :details, dependent: :destroy, class_name: "TudlaAccounting::Detail"
    has_many :entries, through: :details, class_name: "TudlaAccounting::Entry"
    belongs_to :contra_account, class_name: "TudlaAccounting::Account", optional: true
    has_one :contra_for, class_name: "TudlaAccounting::Account", foreign_key: :contra_account_id
    has_one :bank_account_balance, class_name: "TudlaAccounting::BankAccountBalance", dependent: :destroy

    # Where its cash movements go in the cash flow statement. Blank inherits; see
    # cash_flow_section.
    enum :cash_flow_activity, { operating: 0, investing: 1, financing: 2 }, prefix: :cash_flow

    # The cash flow activity in effect: its own, else the nearest parent's, else financing
    # for equity accounts and operating for the rest.
    def cash_flow_section
      [ self, *ancestors.reverse ].find(&:cash_flow_activity)&.cash_flow_activity || (equity? ? "financing" : "operating")
    end

    def debit_balance?
      contra? ? (liability? || equity? || income?) : (asset? || expense?)
    end

    def balance_sheet_account?
      asset? || liability? || equity?
    end

    def role_name = role && self.class.role_name(role)

    def code_with_name
      "#{code} - #{name}"
    end

    def contra?
      contra_account_id.present?
    end

    # Category, parent and contra account decide how balances add up, so they are fixed
    # once anything has been posted to the account.
    def structure_editable?
      details.none? && balances.none?
    end

    # Whether a posted line is on the account or one beneath it. (Opening balances aren't
    # lines: they live only in the balances.)
    def posted_lines_beneath?
      TudlaAccounting::Detail.joins(:entry).where(account_id: subtree.select(:id))
                             .where.not(tudla_accounting_entries: { posted_at: nil }).exists?
    end

    # Only an account with no history, no sub-accounts, nothing offsetting it and no
    # recurring entry, bank rule, budget, tax return or contact using it.
    def deletable?
      structure_editable? && children.none? && contra_for.nil? && RecurringEntryLine.where(account: self).none? &&
        BankRule.where(counter_account_id: id).or(BankRule.where(account_id: id)).none? && BudgetLine.where(account: self).none? &&
        TaxReturnBoxPart.where(account_id: id).none? && Contact.where(default_account_id: id).none? &&
        DocumentLine.where(account_id: id).none?
    end

    # Stops offering the account, and every account beneath it, for new entries: they keep
    # their history and balances, and still show in reports and ledgers. Refused while one
    # of them holds a role, is where an active tax code posts, or has receivables or
    # payables still open (see deactivation_blocker). reactivate! offers it again.
    def deactivate!
      blocker = deactivation_blocker
      raise ArgumentError, blocker if blocker

      transaction do
        closing = subtree.where(active: true).order(ancestry_depth: :desc).to_a # sub-accounts first
        closing.each { |account| account.change_active!(false) }
        audit("account.deactivated", sub_accounts: (closing - [ self ]).map(&:code).sort)
      end
      reload
    end

    # Offers an inactive account for new entries again. Its sub-accounts stay as they
    # are; a sub-account needs its parent active first.
    def reactivate!
      blocker = reactivation_blocker
      raise ArgumentError, blocker if blocker

      transaction do
        change_active!(true)
        audit("account.reactivated")
      end
    end

    # Why deactivate! would be refused, or nil if it can go ahead.
    def deactivation_blocker
      return "#{code_with_name} is inactive already" unless active?

      subtree.where(active: true).order(:code).each do |account|
        problem = account.own_deactivation_problem
        return "#{account.code_with_name} #{problem}" if problem
      end
      nil
    end

    # Why reactivate! would be refused, or nil if it can go ahead.
    def reactivation_blocker
      if active? then "#{code_with_name} is active already"
      elsif parent && !parent.active? then "Reactivate #{parent.code_with_name} first"
      end
    end

    # Why this account alone can't be made inactive (sub-accounts aside), or nil.
    def own_deactivation_problem
      tax_code = TaxCode.where(account: self, active: true).order(:code).first
      recurring = RecurringEntry.active.joins(:lines).where(tudla_accounting_recurring_entry_lines: { account_id: id }).order(:name).first
      rule = BankRule.active.where(counter_account_id: id).or(BankRule.active.where(account_id: id)).order(:name).first
      if role then "is the #{role_name} account; move the role to another account first"
      elsif tax_code then "is where the #{tax_code.code} tax code posts; change its account or make it inactive first"
      elsif recurring then "is used by the recurring entry #{recurring.name}; change it or make it inactive first"
      elsif rule then "is used by the bank rule #{rule.name}; change it or make it inactive first"
      elsif open_items? then "has receivables or payables still open"
      end
    end

    # Saves active alone, for deactivate! and reactivate!, which record it themselves.
    def change_active!(value)
      @changing_active = true
      update!(active: value)
    ensure
      @changing_active = false
    end

    # Lets this account save a change to its role while the block runs. Only for
    # AccountRoleAssigner, which first runs its checks under the posting lock: any other
    # save that changes a role is refused (validate_role_assigned), including other
    # accounts saved inside the block, by callbacks say. It guards against skipping those
    # checks by mistake and isn't a permission (who may change roles is the host's to
    # decide; AccountsController asks for :administer). update_column and update_all get
    # past it, and the database still allows only known roles, one account each.
    def allowing_role_change
      previous, @role_change_allowed = @role_change_allowed, true
      yield
    ensure
      @role_change_allowed = previous
    end

    private

    def audit(action, **details)
      AuditEvent.record!(action, organization: organization, subject: self, details: details)
    end

    def open_items?
      CarryingAmount.joins(:detail).where(tudla_accounting_details: { account_id: id }).includes(:detail, :forex).any? do |carrying_amount|
        carrying_amount.outstanding.values.any?(&:nonzero?)
      end
    end

    # Active accounts sit under active parents, so a parent made inactive takes its
    # sub-accounts with it (deactivate!), and an account can't be added under one.
    def validate_active_parent
      return unless active? && parent && !parent.active?
      return unless new_record? || will_save_change_to_active? || will_save_change_to_ancestry?

      errors.add(:base, "#{parent.code_with_name} is inactive; reactivate it first")
    end

    def validate_deactivation
      problem = own_deactivation_problem || ("has active sub-accounts" if children.where(active: true).exists?)
      errors.add(:base, "#{code_with_name} #{problem}") if problem
    end

    def validate_known_currency
      errors.add(:currency, "is not a known currency code") if currency.present? && Money::Currency.find(currency).nil?
    end

    def validate_structure_unchanged_once_used
      changed_structure = %w[category ancestry contra_account_id] & changed
      return if changed_structure.empty? || structure_editable?

      errors.add(:base, "Category, parent and contra account can't change once the account has postings")
    end

    # A budget's amounts are for income and expense accounts.
    def validate_category_unchanged_in_budgets
      return unless will_save_change_to_category? && BudgetLine.where(account_id: id).exists?

      errors.add(:category, "can't change while a budget has amounts for the account")
    end

    def validate_role_category
      return if role.blank? || !ROLES.key?(role) || category.blank?
      return if ROLES[role][:categories].include?(category)

      errors.add(:role, "needs #{ROLES[role][:needs]} for #{role_name}")
    end

    def validate_role_active
      errors.add(:role, "can't be given to an inactive account") if will_save_change_to_role? && role.present? && !active?
    end

    def validate_role_assigned
      return if !will_save_change_to_role? || @role_change_allowed

      errors.add(:role, "changes only through TudlaAccounting::AccountRoleAssigner")
    end

    def ensure_deletable
      return if deletable?

      errors.add(:base, "Only an account with no postings, sub-accounts, contra accounts, recurring entries, bank rules, budgets, tax returns, contacts or invoices and bills using it can be deleted")
      throw :abort
    end

    def validate_parent
      return if parent_id.nil?

      errors.add(:base, "Attributes are not compatible with parent") if
        category != parent.category
    end
  end
end
