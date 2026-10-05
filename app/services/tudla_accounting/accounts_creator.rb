# frozen_string_literal: true

module TudlaAccounting
  # Creates an organization's chart of accounts from nested data, all or nothing:
  #
  #   AccountsCreator.call([
  #     { code: "1000", name: "Assets", category: "asset", children: [
  #       { code: "1510", name: "Computer Equipment", category: "asset" },
  #       { code: "1515", name: "Accumulated Depreciation", category: "asset", contra_account: "1510" }
  #     ] }
  #   ], organization)
  #
  # Keys may be strings or symbols. `contra_account` names the code of the account it
  # offsets, which must exist in the organization by the end. `currency` defaults to the
  # organization's. Pass a parent account id to create everything beneath an existing account.
  class AccountsCreator
    attr_reader :accounts_data, :organization, :parent

    def self.call(...)
      new(...).call
    end

    def initialize(accounts_data, organization, parent_id = nil)
      @accounts_data = accounts_data
      @organization = organization
      @parent = parent_id.present? ? organization_accounts.find(parent_id) : nil
    end

    # Returns the created accounts.
    def call
      created = []
      contras = []

      ActiveRecord::Base.transaction do
        create_accounts(accounts_data, parent, created, contras)

        contras.each do |account, contra_code|
          offset = organization_accounts.find_by(code: contra_code)
          unless offset
            account.errors.add(:contra_account, "#{contra_code} not found for contra account #{account.code}")
            raise ActiveRecord::RecordInvalid, account
          end
          account.update!(contra_account: offset)
        end
      end

      created
    end

    private

    def organization_accounts
      TudlaAccounting::Account.where(organization: organization)
    end

    def create_accounts(nodes, parent, created, contras)
      nodes.each do |node|
        node = node.to_h.with_indifferent_access
        account = TudlaAccounting::Account.create!(
          organization: organization,
          parent: parent,
          code: node[:code],
          name: node[:name],
          category: node[:category],
          currency: node[:currency].presence || organization.currency
        )
        created << account
        contras << [ account, node[:contra_account] ] if node[:contra_account].present?
        create_accounts(node[:children], account, created, contras) if node[:children].present?
      end
    end
  end
end
