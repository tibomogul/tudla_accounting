# frozen_string_literal: true

module TudlaAccounting
  # Pays a batch of supplier bills from one bank account: one payment per supplier, for
  # what is paid of each of its bills, and optionally each supplier's payment notice
  # emailed. All the payments are recorded or none; ArgumentError names the supplier whose
  # payment couldn't be.
  #
  #   PayRun.call(organization: org, account: bank, paid_on: Date.current, reference: "Pay run 23 Oct",
  #               bills: [ { document: bill, amount_cents: 1_100_00 }, ... ], email: true)
  #   # => #<Result payments=[...] emailed=[...] no_address=[...]>
  #
  # Amounts are in the account's currency, and so must the bills be; a foreign account's
  # payments are at exchange_rate (the date's when not given). With an idempotency_key,
  # each supplier's payment is keyed "<key>:<supplier id>", so the run is made only once.
  # A supplier whose default withholding code is withheld on payment (Contact#
  # payment_withholding_code, such as Australia's no-ABN withholding) has the tax withheld
  # from what is paid of its bills: the bills are settled by the cash and the tax, and
  # the cash is what is paid less the tax. skip_withholding names suppliers (their ids) to
  # pay in full this time, such as one who has since quoted an ABN.
  # PayRun.due lists the bills it could pay: approved, with something still owed, in a
  # currency, due by a date.
  class PayRun
    Result = Struct.new(:payments, :emailed, :no_address, keyword_init: true)

    def self.call(...) = new(...).call

    # Approved bills in currency with something owed, due by due_by (all of them when nil),
    # optionally only one supplier's, by supplier then due date.
    def self.due(organization, currency:, due_by: nil, contact: nil)
      bills = Document.approved.where(organization: organization, kind: "bill", currency: (currency unless currency == organization.currency))
      bills = bills.where(due_on: ..due_by) if due_by
      bills = bills.where(contact: contact) if contact
      bills.with_open_cents.includes(contact: :default_withholding_code).to_a.select { |bill| bill.amount_due.positive? }
           .sort_by { |bill| [ bill.contact.name.downcase, bill.contact_id, bill.due_on || Date::Infinity.new, bill.id ] }
    end

    def initialize(organization:, account:, paid_on:, bills:, reference: nil, exchange_rate: nil, email: false, idempotency_key: nil, skip_withholding: [])
      @organization = organization
      @account = account
      @paid_on = paid_on
      @bills = bills
      @reference = reference
      @exchange_rate = exchange_rate
      @email = email
      @idempotency_key = idempotency_key
      @skip_withholding = Array(skip_withholding).map(&:to_i).to_set
    end

    def call
      raise ArgumentError, "Choose at least one bill to pay" if @bills.empty?

      payments = Payment.transaction do
        @bills.group_by { |bill| bill.fetch(:document).contact }.sort_by { |supplier, _| supplier.name.downcase }.map { |supplier, bills| pay(supplier, bills) }
      end
      result = Result.new(payments: payments, emailed: [], no_address: [])
      payments.each { |payment| notify(payment, result) } if @email
      result
    end

    private

    def pay(supplier, bills)
      settled = bills.sum { |bill| bill.fetch(:amount_cents) }
      code = supplier.payment_withholding_code unless @skip_withholding.include?(supplier.id)
      withholdings = code ? [ { code: code, base_cents: settled, withheld_cents: code.withheld_cents(settled) } ] : []
      Payment.record!(organization: @organization, kind: "paid", contact: supplier, account: @account, paid_on: @paid_on, reference: @reference,
                      exchange_rate: @exchange_rate, amount_cents: settled - withholdings.sum { |withholding| withholding[:withheld_cents] }, applications: bills, withholdings: withholdings,
                      idempotency_key: (@idempotency_key && "#{@idempotency_key}:#{supplier.id}"))
    rescue ArgumentError => e
      raise ArgumentError, "#{supplier.name}: #{e.message.downcase_first}"
    end

    def notify(payment, result)
      draft = EmailDraft.for_payment(payment)
      return result.no_address << payment if draft[:to].blank?

      Delivery.request!(subject: payment, **draft)
      result.emailed << payment
    end
  end
end
