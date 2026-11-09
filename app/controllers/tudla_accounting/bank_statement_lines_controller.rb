module TudlaAccounting
  # Matching one statement line on the banking page, taking a match off, or posting an
  # entry for it. See BankReconciler.
  class BankStatementLinesController < ApplicationController
    permits :post, only: %i[match unmatch create_entry record_by_rule record_payment]

    before_action :set_line

    def match
      details = organization_scope(Detail).where(account: @line.account, id: Array(params[:detail_ids]).compact_blank).includes(:entry).to_a
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
      rate = typed_decimal(params[:rate]) { raise ArgumentError, "The rate #{params[:rate]} isn't a number" }
      entry = @reconciler.create_entry!(@line, account: account, particulars: params[:particulars], rate: rate)
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
    # far as it is owed, the rest a credit for the contact, and matches it. A supplier whose
    # tax is withheld on payment (Contact#payment_withholding_code) was paid the line's
    # amount after the tax, so the bill is settled by both, unless PaymentWithholding says
    # nothing is withheld (an exempt supplier, or a bill under the code's limit).
    def record_payment
      document = organization_scope(Document).approved.find(params.require(:document_id))
      raise ArgumentError, "Choose #{@line.amount_cents.positive? ? 'an invoice' : 'a bill'}" unless document.kind == (@line.amount_cents.positive? ? "sales_invoice" : "bill")

      cents = @line.amount_cents.abs
      withholdings = withheld_from(document, cents)
      settled = cents + withholdings.sum { |withholding| withholding[:withheld_cents] }
      payment = Payment.record!(organization: accounting_organization, kind: document.sales? ? "received" : "paid", contact: document.contact, account: @line.account,
                                paid_on: @line.occurred_on, amount_cents: cents, reference: (@line.reference || @line.description).to_s.first(255), bank_line: @line,
                                applications: [ { document: document, amount_cents: [ settled, document.amount_due.cents ].min } ], withholdings: withholdings)
      done "Recorded #{payment.title.downcase_first} for #{document.number_label} and matched it."
    rescue ArgumentError, ActionController::ParameterMissing => e
      done alert: "No payment was recorded: #{e.message.downcase_first}."
    end

    private

    # The tax withheld from a supplier paid cash_cents for a bill, under its code withheld
    # on payment: from the amount the cash is that amount less the tax of.
    def withheld_from(document, cash_cents)
      code = (PaymentWithholding.new(document.contact, [ { document: document, amount_cents: cash_cents } ]).code if document.purchases?) or return []

      base, withheld = code.split_cash(cash_cents)
      [ { code: code, base_cents: base, withheld_cents: withheld } ]
    end

    def set_line
      @line = organization_scope(BankStatementLine).find(params[:id])
      @reconciler = BankReconciler.new(@line.account)
    end

    def done(notice = nil, alert: nil)
      redirect_to banking_account_path(@line.account, show: params[:show].presence), notice: notice, alert: alert
    end
  end
end
