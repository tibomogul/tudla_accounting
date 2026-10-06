# frozen_string_literal: true

module TudlaAccounting
  # Sets opening balances for an organization as of a date, all or nothing.
  #
  # The date must fall in the first period at every level that contains it (e.g. the
  # first month of the first year), since later periods take their opening balance
  # from earlier ones. Nodes are nested like the account tree:
  #
  #   [{ account_id: 1, amount_cents: 94_000_00, children: [
  #     { account_id: 2, amount_cents: 64_000_00 }, { account_id: 3, amount_cents: 30_000_00 }
  #   ] }]
  #
  # Amounts are signed the natural way for the account's category, so each parent's
  # amount equals the sum of its children's: a contra account (an allowance, accumulated
  # depreciation) is entered as a negative amount. It is stored on the contra account's
  # own side, as posting does. Existing opening balances raise unless overwrite_mode is set. Later balances that already exist are moved by
  # the same amount, so they stay consistent.
  class StartingBalanceCreator
    attr_reader :organization, :date, :nodes, :currency, :overwrite_mode

    def self.call(...)
      new(...).call
    end

    def initialize(organization, date, nodes, currency, overwrite_mode = false)
      @organization = organization
      @date = date
      @nodes = nodes.map { |node| normalize(node) }
      @currency = currency
      @overwrite_mode = overwrite_mode
    end

    def call
      ActiveRecord::Base.transaction do
        organization.class.lock.find(organization.id) # same lock as posting

        periods = TudlaAccounting::Period.periods_for_date(organization, date).order(:from_date, :thru_date).to_a
        raise ArgumentError, "No periods found for the specified date" if periods.empty?

        periods.each do |period|
          if organization_periods(period.siblings).where("from_date < ?", period.from_date).exists?
            raise ArgumentError, "Period #{period.id} has earlier periods; opening balances go in the first period"
          end
        end

        raise ArgumentError, "#{periods.find(&:closed?).label} is closed; reopen it to change the opening balances" if periods.any?(&:closed?)

        nodes.each { |node| check_amounts(node) }
        periods.each { |period| nodes.each { |node| set_amounts(node, period) } }
        TudlaAccounting::AuditEvent.record!("opening_balances.saved", organization: organization,
                                            details: { date: date.to_date.iso8601, overwrite: overwrite_mode })
      end
    end

    private

    def normalize(node)
      node = node.to_h.with_indifferent_access
      { account_id: node[:account_id], amount_cents: node[:amount_cents].to_i, children: Array(node[:children]).map { |child| normalize(child) } }
    end

    def organization_periods(scope)
      scope.where(organization: organization)
    end

    def check_amounts(node)
      children = node[:children]
      if children.any? && children.sum { |child| child[:amount_cents] } != node[:amount_cents]
        raise ArgumentError, "Amounts mismatch for account #{account(node).code}. Parent amount: #{node[:amount_cents]}, " \
                             "Sum of children: #{children.sum { |child| child[:amount_cents] }}"
      end
      children.each { |child| check_amounts(child) }
    end

    def account(node)
      TudlaAccounting::Account.where(organization: organization).find(node[:account_id])
    end

    def set_amounts(node, period)
      account = account(node)
      amount_cents = account.contra? ? -node[:amount_cents] : node[:amount_cents] # stored on the account's own side
      balance = TudlaAccounting::Balance.find_by(account: account, period: period)

      if balance
        raise ArgumentError, "Starting balance for account #{account.code} and period #{period.id} already exists" unless overwrite_mode

        delta = amount_cents - balance.starting_amount_cents
        balance.update!(starting_amount_cents: amount_cents, ending_amount_cents: balance.ending_amount_cents + delta, currency: currency)
      else
        delta = amount_cents
        TudlaAccounting::Balance.create!(account: account, period: period, organization: organization, currency: currency,
                                         starting_amount_cents: delta, current_amount_cents: 0, ending_amount_cents: delta)
      end
      shift_later_balances(account, period, delta)

      node[:children].each { |child| set_amounts(child, period) }
    end

    # Balances in periods after this one (and inside them) took their opening balance
    # from it, so they move by the same amount; later years follow the year-end rules.
    def shift_later_balances(account, period, delta)
      if period.has_parent?
        TudlaAccounting::Balance.shift_balances(account, period.siblings.where("from_date > ?", period.from_date), delta)
      else
        TudlaAccounting::Balance.carry_into_later_years(account, period, delta)
      end
    end
  end
end
