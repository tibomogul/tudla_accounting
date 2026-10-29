# frozen_string_literal: true

module TudlaAccounting
  # Changes accounts' roles (Account::ROLES), the only way they change: a role decides where
  # posting opens what's owed and carries each year's profit. Under the organization's
  # posting lock it moves a role from the account holding it, and refuses a change that
  # would disturb the books:
  #
  # - Receivables and payables stay on an account once it, or one beneath it, has posted
  #   lines (its open items would be left behind), and can't be given to such an account,
  #   whose lines opened nothing owed. Opening balances and drafts don't count.
  # - The receivable and payable accounts are totals of their sub-accounts: one in each
  #   currency the organization deals in (see Account.for_role_in_currency!). Giving
  #   either role makes the one in the organization's own currency (e.g. "1100-USD") when
  #   the account has none, moving the account's own opening balance onto it, so the
  #   account still adds up to what is beneath it.
  # - Retained earnings can't change while a period after the first year is closed, as the
  #   profit carried into it would be restated. Changing it on books with balances rebuilds
  #   them (BalanceRebuilder#rebuild!) in the same transaction, so they're never left behind.
  #
  #   AccountRoleAssigner.save(account, "retained_earnings") # => true, or false with account.errors
  #   AccountRoleAssigner.save!(account, nil)                # or ActiveRecord::RecordInvalid
  #
  # Several changes in one transaction, all or nothing, with at most one rebuild, at the end:
  #
  #   AccountRoleAssigner.batch(organization) do |assigner|
  #     assigner.save(receivables, "receivable")
  #     assigner.save(retained, "retained_earnings")
  #   end
  #
  # The account may be new or have other unsaved changes; they're saved with the role.
  class AccountRoleAssigner
    # Roles that open what is owed as their lines post.
    LOCKED_ROLES = %w[receivable payable].freeze

    # Yields an assigner, then rebuilds the balances if its changes need it; returns the
    # block's value. All or nothing: when a save in the block returns false, every change
    # made in it is rolled back, nothing is rebuilt, and batch returns false (the account
    # refused has the errors). A savepoint, so this holds inside a caller's transaction too.
    def self.batch(organization)
      result = false
      ActiveRecord::Base.transaction(requires_new: true) do
        assigner = new(organization)
        result = yield assigner
        if assigner.failed?
          result = false
          raise ActiveRecord::Rollback
        end
        assigner.rebuild_if_needed!
      end
      result
    end

    def self.save(account, role)
      batch(account.organization) { |assigner| assigner.save(account, role) }
    end

    def self.save!(account, role)
      batch(account.organization) { |assigner| assigner.save!(account, role) }
    end

    # Refuses a role given to more than one of the accounts, as [code, role] pairs: saved in
    # turn, each would take it from the one before. (A file or chart naming one twice is a
    # mistake; moving a role from an account outside them is not.)
    def self.check_unique!(codes_and_roles)
      codes_and_roles.group_by { |_, role| role.to_s }.each do |role, pairs|
        next if pairs.one?

        raise ArgumentError, "Role #{Account::ROLES.dig(role, :name) || role} is given to more than one account: #{pairs.map(&:first).join(', ')}"
      end
    end

    def initialize(organization)
      @organization = organization
    end

    def save(account, role)
      raise ArgumentError, "#{account.code} isn't one of #{TudlaAccounting.organization_label(@organization)}'s accounts" unless account.organization == @organization

      account.role = role
      saved = if account.will_save_change_to_role?
        ActiveRecord::Base.transaction(requires_new: true) do
          # The posting lock, so the checks see what posting and other role changes leave, and
          # two assignments of one role can't both find it free.
          @organization.class.lock.find(@organization.id)
          account.allowing_role_change { assign(account) } or raise ActiveRecord::Rollback
          true
        end || false
      else
        account.save
      end
      @failed ||= !saved
      saved
    end

    def save!(account, role)
      save(account, role) or raise ActiveRecord::RecordInvalid, account
    end

    # Whether a save returned false (batch then rolls back).
    def failed? = @failed || false

    # Rebuilds the balances if a change moved retained earnings on books that have them.
    # batch calls it; a caller using new directly calls it once the balances the rebuild
    # should see are written (ChartOfAccountsLoader, after the opening balances).
    def rebuild_if_needed!
      return unless @rebuild_needed

      BalanceRebuilder.new(@organization).rebuild!
      @rebuild_needed = false
    end

    private

    def assign(account)
      account.valid?
      check_locked_roles(account)
      check_periods_open(account)
      return false if account.errors.any?

      rebuild = rebuild_needed?(account)
      return false unless release_role(account) && account.save && ensure_home_sub_account(account)

      @rebuild_needed ||= rebuild
      true
    end

    # The receivable or payable account's sub-account in the organization's currency, made
    # if it has none, with the account's own opening balance (what it holds beyond the
    # accounts beneath it) in every period it has a balance for. Nothing is posted beneath
    # it yet (check_locked_roles), so that is all its balances hold.
    def ensure_home_sub_account(account)
      return true unless LOCKED_ROLES.include?(account.role)

      currency = @organization.currency
      return true if account.children.exists?(currency: currency)

      code = "#{account.code}-#{currency}"
      if Account.exists?(organization: @organization, code: code)
        account.errors.add(:role, "needs a sub-account in #{currency} for #{account.role_name.downcase} in #{currency}, made as #{code}, but #{code} is already taken; " \
                                  "move that account beneath #{account.code}, or give it another code")
        return false
      end

      home = Account.create!(organization: @organization, parent: account, code: code, name: "#{account.name} - #{currency}", category: account.category,
                             currency: currency, contra_account_id: account.contra_account_id)
      move_own_balances(account, home)
      true
    end

    def move_own_balances(account, home)
      others = account.children.where.not(id: home.id).to_a
      Balance.where(account: account).find_each do |balance|
        beneath = Balance.peek_all(others, balance.period).values
        own = %i[starting_amount_cents current_amount_cents ending_amount_cents].to_h do |field|
          [ field, balance.public_send(field) - beneath.sum { |child| (child.account.debit_balance? == account.debit_balance? ? 1 : -1) * child.public_send(field) } ]
        end
        next if own.values.all?(&:zero?)

        Balance.create!(own.merge(organization: @organization, account: home, period: balance.period, currency: balance.currency))
      end
    end

    def check_locked_roles(account)
      return unless account.persisted? && account.posted_lines_beneath?

      if LOCKED_ROLES.include?(account.role_in_database)
        account.errors.add(:role, "stays #{Account.role_name(account.role_in_database)} now that it, or an account beneath it, has posted lines")
      elsif LOCKED_ROLES.include?(account.role)
        account.errors.add(:role, "#{account.role_name} can't be given to an account with posted lines, which opened nothing owed; " \
                                  "mark it before posting, or use a new account")
      end
    end

    # Each later year adds the profit of the years before it to retained earnings, so
    # changing the account restates every year after the first, and a closed period's
    # balances stay as they were closed.
    def check_periods_open(account)
      return unless retained_earnings_change?(account)

      periods = Period.where(organization: @organization)
      first_year = periods.roots.order(:from_date).first or return
      latest = periods.where.not(closed_at: nil).where("from_date > ?", first_year.thru_date).order(:from_date, :thru_date).last or return

      account.errors.add(:role, "can't change from or to Retained earnings while periods after #{first_year.label} are closed, as the profit " \
                                "carried into them would be restated; reopen them first (the latest closed is #{latest.label})")
    end

    def retained_earnings_change?(account)
      [ account.role_in_database, account.role ].include?("retained_earnings")
    end

    # Marking retained earnings late, moving it or taking it off changes where the earlier
    # years' profit belongs.
    def rebuild_needed?(account)
      retained_earnings_change?(account) && Balance.where(organization: @organization).exists?
    end

    # Takes the role from the account holding it, unless that account must keep it.
    def release_role(account)
      return true if account.role.nil?

      holder = Account.where(organization: @organization, role: account.role).where.not(id: account.id).first
      return true unless holder

      if LOCKED_ROLES.include?(holder.role) && holder.posted_lines_beneath?
        account.errors.add(:role, "#{account.role_name} is held by #{holder.code_with_name}, which keeps it now that it, or an account beneath it, has posted lines")
        return false
      end

      holder.role = nil
      return true if holder.allowing_role_change { holder.save }

      holder.errors.full_messages.each { |message| account.errors.add(:role, "can't move from #{holder.code_with_name}: #{message}") }
      false
    end
  end
end
