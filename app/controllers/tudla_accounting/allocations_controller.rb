module TudlaAccounting
  # Applying a payment or credit note (an entry's) to what is owed on invoices or bills, and
  # taking it off again, from its entry's page or (back) the payment's, credit note's or
  # contact's page, which it returns to. See Allocator.
  class AllocationsController < ApplicationController
    permits :post, only: %i[create oldest_first reverse]

    before_action :set_credit_entry, only: %i[create oldest_first]

    def create
      charge = Allocator.open_charges(@credit_entry).find { |candidate| candidate.id == params.require(:to_id).to_i }
      raise ArgumentError, "Choose an invoice or bill that is still owed" unless charge

      allocation = Allocator.allocate!(@credit_entry, charge, at: on, **amount(charge))
      redirect_to back_or(entry_path(@credit_entry)), notice: "Applied #{helpers.tc_money(allocation.amount)} to #{charge.detail.entry.particulars}."
    rescue ArgumentError, ActionController::ParameterMissing => e
      redirect_to back_or(entry_path(@credit_entry)), alert: "Nothing was applied: #{e.message.downcase_first}."
    end

    def oldest_first
      made = Allocator.allocate_oldest_first!(@credit_entry, at: on)
      notice = made.empty? ? "Nothing is owed that it could be applied to." : "Applied to #{made.map { |allocation| allocation.to.detail.entry.particulars }.to_sentence}."
      redirect_to back_or(entry_path(@credit_entry)), notice: notice
    rescue ArgumentError => e
      redirect_to back_or(entry_path(@credit_entry)), alert: "Nothing was applied: #{e.message.downcase_first}."
    end

    def reverse
      allocation = organization_scope(Allocation).find(params[:id])
      Allocator.unallocate!(allocation, at: on)
      redirect_to back_or(entry_path(allocation.from.detail.entry)), notice: "Took #{helpers.tc_money(allocation.amount)} off #{allocation.to.detail.entry.particulars}."
    rescue ArgumentError => e
      redirect_to back_or(entry_path(allocation.from.detail.entry)), alert: "It was not taken off: #{e.message.downcase_first}."
    end

    private

    def set_credit_entry
      @credit_entry = organization_scope(Entry).find(params.require(:entry_id))
    end

    # The page the form was on, when it is this app's.
    def back_or(fallback) = url_from(params[:back]) || fallback

    def on
      date = params[:on].presence&.to_date || Date.current
      ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone].local(date.year, date.month, date.day)
    end

    # A typed amount is in the foreign currency when a foreign payment is applied to a
    # foreign invoice, otherwise in the organization's currency; blank applies the most.
    def amount(charge)
      return {} if params[:amount].blank?

      credit = Allocator.carrying_amount(@credit_entry)
      currency = credit.forex && charge.forex ? charge.forex.other_currency : accounting_organization.currency
      cents = AmountParser.cents(params[:amount], currency)
      credit.forex && charge.forex ? { other_currency_cents: cents } : { amount_cents: cents }
    end
  end
end
