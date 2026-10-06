module TudlaAccounting
  # Applying a payment or credit note (the entry whose page these forms are on) to what is
  # owed on invoices or bills, and taking it off again. See Allocator.
  class AllocationsController < ApplicationController
    before_action :set_credit_entry, only: %i[create oldest_first]

    def create
      charge = Allocator.open_charges(@credit_entry).find { |candidate| candidate.id == params.require(:to_id).to_i }
      raise ArgumentError, "Choose an invoice or bill that is still owed" unless charge

      allocation = Allocator.allocate!(@credit_entry, charge, at: on, **amount(charge))
      redirect_to entry_path(@credit_entry), notice: "Applied #{helpers.tc_money(allocation.amount)} to #{charge.detail.entry.particulars}."
    rescue ArgumentError, ActionController::ParameterMissing => e
      redirect_to entry_path(@credit_entry), alert: "Nothing was applied: #{e.message.downcase_first}."
    end

    def oldest_first
      made = Allocator.allocate_oldest_first!(@credit_entry, at: on)
      notice = made.empty? ? "Nothing is owed that it could be applied to." : "Applied to #{made.map { |allocation| allocation.to.detail.entry.particulars }.to_sentence}."
      redirect_to entry_path(@credit_entry), notice: notice
    rescue ArgumentError => e
      redirect_to entry_path(@credit_entry), alert: "Nothing was applied: #{e.message.downcase_first}."
    end

    def reverse
      allocation = organization_scope(Allocation).find(params[:id])
      Allocator.unallocate!(allocation, at: on)
      redirect_to entry_path(allocation.from.detail.entry), notice: "Took #{helpers.tc_money(allocation.amount)} off #{allocation.to.detail.entry.particulars}."
    rescue ArgumentError => e
      redirect_to entry_path(allocation.from.detail.entry), alert: "It was not taken off: #{e.message.downcase_first}."
    end

    private

    def set_credit_entry
      @credit_entry = organization_scope(Entry).find(params.require(:entry_id))
    end

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
      cents = Money.from_amount(BigDecimal(params[:amount].to_s.delete(",")), currency).cents
      credit.forex && charge.forex ? { other_currency_cents: cents } : { amount_cents: cents }
    rescue ArgumentError
      raise ArgumentError, "#{params[:amount]} isn't an amount"
    end
  end
end
