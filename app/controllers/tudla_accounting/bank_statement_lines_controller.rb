module TudlaAccounting
  # Matching one statement line on the banking page, taking a match off, or posting an
  # entry for it. See BankReconciler.
  class BankStatementLinesController < ApplicationController
    permits :post, only: %i[match unmatch create_entry]

    before_action :set_line

    def match
      details = Detail.where(account: @line.account, id: Array(params[:detail_ids]).compact_blank).includes(:entry).to_a
      @reconciler.match!(@line, details)
      done "Matched #{@line.description}."
    rescue ArgumentError => e
      done alert: "It was not matched: #{e.message.downcase_first}."
    end

    def unmatch
      @reconciler.unmatch!(@line)
      done "Took the match off #{@line.description}."
    rescue ArgumentError => e
      done alert: "#{e.message}."
    end

    def create_entry
      account = organization_scope(Account).find(params.require(:counter_account_id))
      entry = @reconciler.create_entry!(@line, account: account, particulars: params[:particulars], rate: params[:rate])
      done "Posted #{entry.particulars} and matched it."
    rescue ArgumentError, ActiveRecord::RecordInvalid, ActionController::ParameterMissing => e
      done alert: "No entry was posted: #{e.message.downcase_first}."
    end

    private

    def set_line
      @line = organization_scope(BankStatementLine).find(params[:id])
      @reconciler = BankReconciler.new(@line.account)
    end

    def done(notice = nil, alert: nil)
      redirect_to banking_account_path(@line.account, show: params[:show].presence), notice: notice, alert: alert
    end
  end
end
