module TudlaAccounting
  # The supplier pay run: the bills due by a date (from one bank account's currency, all
  # suppliers or one), chosen and paid in one go, one payment per supplier, with their
  # payment notices emailed. Needs :post. See PayRun.
  class PayRunsController < ApplicationController
    include PaymentChoices

    permits :post, only: %i[new create]

    def new
      load_bills(params)
      @selected = @bills.map(&:id).to_set
      @amounts = {}
      @pay_run = { paid_on: today, reference: "Pay run #{today.strftime('%-d %b %Y')}", email: true }
    end

    def create
      permitted = params.require(:pay_run).permit(:account_id, :due_by, :contact_id, :paid_on, :reference, :exchange_rate, :email, pay: {}, amounts: {})
      load_bills(permitted)
      problems = []
      @selected = (permitted[:pay]&.to_h || {}).select { |_id, chosen| chosen == "1" }.keys.map(&:to_i).to_set
      @amounts = (permitted[:amounts]&.to_h || {}).transform_keys(&:to_i)
      @pay_run = { paid_on: permitted[:paid_on], reference: permitted[:reference], email: permitted[:email] == "1", exchange_rate: permitted[:exchange_rate] }
      paid_on = iso_date(permitted[:paid_on])
      problems << "Give the date it is paid" unless paid_on
      rate = typed_decimal(permitted[:exchange_rate]) { problems << "#{permitted[:exchange_rate]} isn't an exchange rate" }
      bills = organization_scope(Document).where(id: @selected.to_a).index_by(&:id)
      chosen = @selected.map do |id|
        bill = bills.fetch(id) { raise ActiveRecord::RecordNotFound }
        cents = amount_cents(@amounts[id], @currency) { problems << "#{@amounts[id]} isn't an amount (#{bill.number_label})" }
        { document: bill, amount_cents: cents || bill.amount_due.cents }
      end
      raise ArgumentError, problems.to_sentence if problems.any?

      result = PayRun.call(organization: accounting_organization, account: @account, paid_on: paid_on, bills: chosen, reference: permitted[:reference],
                           exchange_rate: rate, email: @pay_run[:email])
      redirect_to paid_payments_path, notice: notice(result)
    rescue ArgumentError => e
      @error = e.message
      render :new, status: :unprocessable_entity
    end

    private

    def today
      ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone].today
    end

    # The account paid from (as a payment's by default), its currency, the date the
    # bills are due by (a week from today by default), the supplier (any), and the bills.
    def load_bills(given)
      @account = bank_accounts.find_by(id: given[:account_id].presence || default_account_id(accounting_organization.currency)) || bank_accounts.first
      @currency = @account&.currency.presence || accounting_organization.currency
      @due_by = iso_date(given[:due_by]) || today + 7
      @contact = organization_scope(Contact).suppliers.find(given[:contact_id]) if given[:contact_id].present?
      @bills = @account ? PayRun.due(accounting_organization, currency: @currency, due_by: @due_by, contact: @contact) : []
    end

    def iso_date(text)
      Date.iso8601(text.to_s)
    rescue Date::Error
      nil
    end

    def notice(result)
      payments = result.payments
      total = payments.sum(Money.new(0, @currency), &:amount)
      text = +"Paid #{helpers.pluralize(payments.size, 'supplier')} #{@currency} #{helpers.tc_money(total)} in all."
      text << " Emailing payment notices to #{result.emailed.map { |payment| payment.contact.name }.to_sentence}." if result.emailed.any?
      text << " Not emailed, as they have no email address: #{result.no_address.map { |payment| payment.contact.name }.to_sentence}." if result.no_address.any?
      text
    end
  end
end
