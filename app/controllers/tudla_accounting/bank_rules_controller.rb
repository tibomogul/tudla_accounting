module TudlaAccounting
  # Bank rules: how to record statement lines the books don't have yet. See BankRule.
  class BankRulesController < ApplicationController
    permits :post, only: %i[new create edit update destroy] # rules decide what gets posted

    before_action :set_bank_rule, only: %i[edit update destroy]
    helper_method :bank_accounts, :rule_accounts

    def index
      @bank_rules = organization_scope(BankRule).in_order.includes(:account, :counter_account, :tax_code).to_a
    end

    # A new rule, or (line_id) one for lines like a statement line.
    def new
      @bank_rule = organization_scope(BankRule).new(position: next_position)
      return if params[:line_id].blank?

      line = organization_scope(BankStatementLine).find(params[:line_id])
      @bank_rule.assign_attributes(name: line.description.truncate(60), description_contains: line.description, account: line.account,
                                   direction: line.amount_cents.positive? ? "in" : "out")
    end

    def create
      @bank_rule = organization_scope(BankRule).new
      save(:new)
    end

    def edit
    end

    def update
      save(:edit)
    end

    def destroy
      @bank_rule.destroy!
      redirect_to bank_rules_path, notice: "Bank rule #{@bank_rule.name} deleted."
    end

    private

    def set_bank_rule
      @bank_rule = organization_scope(BankRule).find(params[:id])
    end

    def save(form)
      problems = assign_rule
      if problems.empty? && @bank_rule.save
        redirect_to bank_rules_path, notice: "Bank rule #{@bank_rule.name} saved."
      else
        problems.each { |problem| @bank_rule.errors.add(:base, problem) }
        render form, status: :unprocessable_entity
      end
    end

    # The form's fields as the rule's, accounts, tax code and dimension values the
    # organization's own; anything typed that isn't an amount, as problems.
    def assign_rule
      permitted = params.require(:bank_rule).permit(:name, :position, :account_id, :description_contains, :direction, :amount_min, :amount_max,
                                                    :counter_account_id, :tax_code_id, :particulars, :active)
      problems = []
      currency = accounting_organization.currency
      amounts = %i[amount_min amount_max].to_h do |field|
        [ :"#{field}_cents", amount_cents(permitted[field], currency) { |problem| problems << "#{field.to_s.humanize}: #{problem}" }&.abs ]
      end
      @bank_rule.assign_attributes(permitted.slice(:name, :position, :description_contains, :direction, :particulars, :active).to_h.merge(amounts).merge(
        account_id: (organization_scope(Account).find(permitted[:account_id]).id if permitted[:account_id].present?),
        counter_account_id: (organization_scope(Account).find(permitted[:counter_account_id]).id if permitted[:counter_account_id].present?),
        tax_code_id: (organization_scope(TaxCode).find(permitted[:tax_code_id]).id if permitted[:tax_code_id].present?),
        dimension_value_ids: dimension_value_ids
      ))
      problems
    end

    # The values chosen, one per dimension, each the organization's (looked up by id, so
    # nothing else of the request is used).
    def dimension_value_ids
      chosen = params[:bank_rule][:dimensions]
      chosen = chosen.respond_to?(:to_unsafe_h) ? chosen.to_unsafe_h : {}
      chosen.filter_map do |dimension_id, value_id|
        organization_scope(Dimension).find(dimension_id).dimension_values.find(value_id).id if value_id.present?
      end
    end

    def next_position
      (organization_scope(BankRule).maximum(:position) || 0) + 10
    end

    # Accounts a rule can be for: the organization's assets and liabilities.
    def bank_accounts
      organization_scope(Account).where(category: [ Account::CATEGORY_ASSET, Account::CATEGORY_LIABILITY ]).order(:code)
    end

    def rule_accounts
      organization_scope(Account).order(:code)
    end
  end
end
