module TudlaAccounting
  # The organization's tax codes, set up alongside the chart of accounts.
  class TaxCodesController < ApplicationController
    permits :administer, only: %i[index new create edit update destroy]

    before_action :set_tax_code, only: %i[edit update destroy]
    helper_method :tax_accounts

    def index
      @tax_codes = organization_scope(TaxCode).includes(:account).order(:kind, :code)
      @used = Detail.where(tax_code_id: @tax_codes.map(&:id)).distinct.pluck(:tax_code_id).to_set
    end

    def new
      @tax_code = organization_scope(TaxCode).new(kind: params[:kind] || :sales)
    end

    def create
      @tax_code = organization_scope(TaxCode).new(tax_code_params)
      if @tax_code.save
        redirect_to tax_codes_path, notice: "Tax code #{@tax_code.label} was added."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @tax_code.update(tax_code_params)
        redirect_to tax_codes_path, notice: "Tax code #{@tax_code.label} was saved."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      if @tax_code.destroy
        redirect_to tax_codes_path, notice: "Tax code #{@tax_code.code} was deleted."
      else
        redirect_to tax_codes_path, alert: @tax_code.errors.full_messages.to_sentence
      end
    end

    private

    def tax_accounts
      organization_scope(Account).order(:code)
    end

    def set_tax_code
      @tax_code = organization_scope(TaxCode).find(params[:id])
    end

    def tax_code_params
      permitted = params.require(:tax_code).permit(:code, :name, :rate_percent, :kind, :account_id, :active)
      permitted[:account_id] = organization_scope(Account).find(permitted[:account_id]).id if permitted[:account_id].present?
      permitted
    end
  end
end
