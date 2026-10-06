# frozen_string_literal: true

module TudlaAccounting
  # Opening balances as entered on the screen: one amount for each account without
  # sub-accounts (parents add up their children), contra accounts entered as positive
  # amounts that reduce their category. Saves them through StartingBalanceCreator at the
  # start of the organization's first financial year, replacing any there already.
  class OpeningBalancesForm
    attr_reader :organization, :year, :accounts, :errors

    def initialize(organization)
      @organization = organization
      @year = TudlaAccounting::Period.roots.where(organization: organization).order(:from_date).first
      @accounts = TudlaAccounting::Account.where(organization: organization).order(:code).to_a
      @children = @accounts.group_by(&:parent_id)
      @amounts = {}
      @errors = []
    end

    # Accounts that take an amount; parents are worked out from them.
    def leaf?(account)
      @children.fetch(account.id, []).empty?
    end

    # Counts on the debit side of the balance check (assets and expenses, unless contra).
    def debit_side?(account)
      account.debit_balance?
    end

    # The amount shown for an account, as entered: on its own side (a contra account's
    # deduction is positive). A parent's is the total of its children on its side.
    def amount(account)
      return @amounts[account.id] if @amounts.key?(account.id)
      return Money.new(0, currency) unless year

      @year_balances ||= TudlaAccounting::Balance.peek_all(accounts, year)
      Money.new(@year_balances.fetch(account.id).starting_amount_cents, currency)
    end

    def parent_total(account)
      @children.fetch(account.id, []).sum(Money.new(0, currency)) do |child|
        child_amount = leaf?(child) ? amount(child) : parent_total(child)
        child.debit_balance? == account.debit_balance? ? child_amount : -child_amount
      end
    end

    def total(side)
      leaves = @accounts.select { |account| leaf?(account) && debit_side?(account) == (side == :debit) }
      leaves.sum(Money.new(0, currency)) { |account| amount(account) }
    end

    def balanced?
      total(:debit) == total(:credit)
    end

    # Takes the typed amounts ({ account_id => "1,234.50" }) and saves them if they're
    # numbers and balance. Returns true when saved.
    def save(typed)
      raise ArgumentError, "Create a financial year first" unless year

      @accounts.select { |account| leaf?(account) }.each do |account|
        text = typed.fetch(account.id.to_s, "").to_s.strip.delete(",")
        @amounts[account.id] = text.empty? ? Money.new(0, currency) : Money.from_amount(BigDecimal(text), currency)
      rescue ArgumentError
        @amounts[account.id] = Money.new(0, currency)
        @errors << "#{account.code_with_name}: #{typed[account.id.to_s]} isn't an amount"
      end
      if @errors.empty? && !balanced?
        @errors << "Debits (#{total(:debit).format(symbol: false)}) and credits (#{total(:credit).format(symbol: false)}) don't balance, in #{currency}"
      end
      return false if @errors.any?

      StartingBalanceCreator.call(organization, year.from_date.to_date, roots.map { |account| node(account) }, currency, true)
      true
    end

    private

    def currency
      organization.currency
    end

    def roots
      @accounts.select { |account| account.parent_id.nil? }
    end

    # StartingBalanceCreator's nodes are signed the natural way for the category, so a
    # contra account's deduction is negative.
    def node(account)
      own = leaf?(account) ? amount(account) : parent_total(account)
      { account_id: account.id, amount_cents: (account.contra? ? -own : own).cents,
        children: @children.fetch(account.id, []).map { |child| node(child) } }
    end
  end
end
