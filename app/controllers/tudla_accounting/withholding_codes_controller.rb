module TudlaAccounting
  # The organization's withholding codes, set up alongside its tax codes.
  class WithholdingCodesController < ApplicationController
    permits :administer, only: %i[index new create edit update destroy add_template]

    before_action :set_withholding_code, only: %i[edit update destroy]
    helper_method :payable_accounts, :creditable_accounts

    def index
      @withholding_codes = organization_scope(WithholdingCode).includes(:payable_account, :creditable_account).order(:code)
    end

    def new
      @withholding_code = organization_scope(WithholdingCode).new
    end

    def create
      @withholding_code = organization_scope(WithholdingCode).new(withholding_code_params)
      if @withholding_code.save
        redirect_to withholding_codes_path, notice: "Withholding code #{@withholding_code.label} was added."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @withholding_code.update(withholding_code_params)
        redirect_to withholding_codes_path, notice: "Withholding code #{@withholding_code.label} was saved."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      if @withholding_code.destroy
        redirect_to withholding_codes_path, notice: "Withholding code #{@withholding_code.code} was deleted."
      else
        redirect_to withholding_codes_path, alert: @withholding_code.errors.full_messages.to_sentence
      end
    end

    # Adds a ready-made list's codes the organization doesn't have yet.
    def add_template
      added = WithholdingCodeTemplates.add!(accounting_organization, params[:template], payable_account: chosen_account(:payable_account_id), creditable_account: chosen_account(:creditable_account_id))
      redirect_to withholding_codes_path, notice: added.zero? ? "You have all of that list's codes already." : "#{helpers.pluralize(added, 'withholding code')} added. Check their rates before relying on them."
    rescue ArgumentError => e
      redirect_to withholding_codes_path, alert: e.message
    end

    private

    def payable_accounts = offered_accounts(Account::CATEGORY_LIABILITY)
    def creditable_accounts = offered_accounts(Account::CATEGORY_ASSET)

    # The category's accounts, without receivables or payables and their sub-accounts.
    def offered_accounts(category)
      control = organization_scope(Account).where(role: %w[receivable payable]).flat_map(&:subtree_ids)
      organization_scope(Account).where(category: category).where.not(id: control).order(:code)
    end

    def chosen_account(field) = params[field].presence && organization_scope(Account).find(params[field])

    def set_withholding_code
      @withholding_code = organization_scope(WithholdingCode).find(params[:id])
    end

    def withholding_code_params
      permitted = params.require(:withholding_code).permit(:code, :name, :rate_percent, :payable_account_id, :creditable_account_id, :withheld_on, :active)
      %i[payable_account_id creditable_account_id].each { |field| permitted[field] = organization_scope(Account).find(permitted[field]).id if permitted[field].present? }
      permitted
    end
  end
end
