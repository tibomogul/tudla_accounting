module TudlaAccounting
  # Matching one statement line on the banking page, taking a match off, or posting an
  # entry for it. See BankReconciler.
  class BankStatementLinesController < ApplicationController
    permits :post, only: %i[match unmatch create_entry record_by_rule record_payment]

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

    # Records the line by the bank rule that suggests it.
    def record_by_rule
      rule = @reconciler.rule_suggestions[@line]
      return done alert: "No rule suggests how to record #{@line.description}." unless rule

      entry = @reconciler.record_by_rule!(@line, rule)
      done "Posted #{entry.particulars} and matched it."
    rescue ArgumentError, ActiveRecord::RecordInvalid => e
      done alert: "It was not recorded: #{e.message.downcase_first}."
    end

    # Records the line as a payment of an open invoice (money in) or bill (money out), as
    # far as it is owed, the rest a credit for the contact, and matches it.
    def record_payment
      document = organization_scope(Document).approved.find(params.require(:document_id))
      raise ArgumentError, "Choose #{@line.amount_cents.positive? ? 'an invoice' : 'a bill'}" unless document.kind == (@line.amount_cents.positive? ? "sales_invoice" : "bill")

      cents = @line.amount_cents.abs
      payment = Payment.record!(organization: accounting_organization, kind: document.sales? ? "received" : "paid", contact: document.contact, account: @line.account,
                                paid_on: @line.occurred_on, amount_cents: cents, reference: (@line.reference || @line.description).to_s.first(255), bank_line: @line,
                                applications: [ { document: document, amount_cents: [ cents, document.amount_due.cents ].min } ])
      done "Recorded #{payment.title.downcase_first} for #{document.number_label} and matched it."
    rescue ArgumentError, ActionController::ParameterMissing => e
      done alert: "No payment was recorded: #{e.message.downcase_first}."
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
