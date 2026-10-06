# frozen_string_literal: true

module TudlaAccounting
  # What was taxed under each tax code in a span of time, and the tax owed or claimable,
  # from the lines posted in it (accrual basis, by posting time):
  #
  #   TaxReport.call(organization, from: Time.zone.local(2026, 1, 1), thru: Time.zone.local(2026, 3, 31).end_of_day)
  #   # => { codes: [{ tax_code:, base:, tax: }, ...], sales: { base:, tax: }, purchases: { base:, tax: }, net_tax: }
  #
  # A sales code counts credits up and debits down (a reversal or credit note reduces it);
  # a purchases code the other way round. net_tax is the tax on sales less the tax on
  # purchases: positive is owed to the tax authority, negative is a refund due. Codes with
  # nothing posted are listed while they are active.
  class TaxReport
    def self.call(...)
      new(...).call
    end

    def initialize(organization, from:, thru:)
      @organization = organization
      @from = from
      @thru = thru
    end

    def call
      codes = TaxCode.where(organization: @organization).order(:kind, :code).map do |code|
        { tax_code: code, base: money(signed(code, :base)), tax: money(signed(code, :tax)) }
      end
      codes.reject! { |row| !row[:tax_code].active? && row[:base].zero? && row[:tax].zero? }
      sales, purchases = %w[sales purchases].map do |kind|
        rows = codes.select { |row| row[:tax_code].kind == kind }
        { base: rows.sum(money(0)) { |row| row[:base] }, tax: rows.sum(money(0)) { |row| row[:tax] } }
      end
      { codes: codes, sales: sales, purchases: purchases, net_tax: sales[:tax] - purchases[:tax], from: @from, thru: @thru }
    end

    private

    # { [tax_code_id, tax_role, tally] => cents } for the lines posted in the span.
    def totals
      @totals ||= Detail.joins(:entry)
        .where(organization_type: @organization.class.name, organization_id: @organization.id)
        .where.not(tax_code_id: nil)
        .where(tudla_accounting_entries: { posted_at: @from..@thru })
        .group(:tax_code_id, :tax_role, :tally).sum(:amount_cents)
    end

    def signed(code, role)
      credits = totals.fetch([ code.id, role.to_s, Detail::TALLY_CREDIT ], 0)
      debits = totals.fetch([ code.id, role.to_s, Detail::TALLY_DEBIT ], 0)
      code.sales? ? credits - debits : debits - credits
    end

    def money(cents)
      Money.new(cents, @organization.currency)
    end
  end
end
