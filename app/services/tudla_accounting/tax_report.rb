# frozen_string_literal: true

module TudlaAccounting
  # What was taxed under each tax code in a span of time, and the tax owed or claimable:
  #
  #   TaxReport.call(organization, from: Time.zone.local(2026, 1, 1), thru: Time.zone.local(2026, 3, 31).end_of_day)
  #   # => { codes: [{ tax_code:, base:, tax: }, ...], sales: { base:, tax: }, purchases: { base:, tax: }, net_tax:, basis: }
  #
  # On the accrual basis (the default, or the tax_basis setting) tax counts when its lines
  # are posted. On the cash basis it counts when money changes hands: an entry that opens
  # no receivable or payable (a cash sale, an expense paid on the spot) when posted; an
  # invoice, bill or taxed credit note as it is settled, each allocation in the span
  # counting the share of the entry it settles (taken off again, the same share back);
  # and the reversal of an invoice or bill not at all, since only its settlements counted.
  #
  # A sales code counts credits up and debits down (a reversal or credit note reduces it);
  # a purchases code the other way round. net_tax is the tax on sales less the tax on
  # purchases: positive is owed to the tax authority, negative is a refund due. Codes with
  # nothing in the span are listed while they are active.
  class TaxReport
    BASES = %i[accrual cash].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(organization, from:, thru:, basis: nil)
      @organization = organization
      @from = from
      @thru = thru
      @basis = (basis || TudlaAccounting.configuration.tax_basis || :accrual).to_sym
      raise ArgumentError, "basis must be one of #{BASES.join(', ')}" unless BASES.include?(@basis)
    end

    def call
      codes = TaxCode.where(organization: @organization).order(:kind, :code).map do |code|
        { tax_code: code, base: money(amounts.fetch([ code.id, "base" ], 0)), tax: money(amounts.fetch([ code.id, "tax" ], 0)) }
      end
      codes.reject! { |row| !row[:tax_code].active? && row[:base].zero? && row[:tax].zero? }
      sales, purchases = %w[sales purchases].map do |kind|
        rows = codes.select { |row| row[:tax_code].kind == kind }
        { base: rows.sum(money(0)) { |row| row[:base] }, tax: rows.sum(money(0)) { |row| row[:tax] } }
      end
      { codes: codes, sales: sales, purchases: purchases, net_tax: sales[:tax] - purchases[:tax], from: @from, thru: @thru, basis: @basis }
    end

    private

    # { [tax_code_id, "base" or "tax"] => cents, signed by the code's kind } for the span.
    def amounts
      @amounts ||= if @basis == :cash
        add(signed(taxed_lines.where(tudla_accounting_entries: { posted_at: @from..@thru }).where.not(entry_id: settled_entry_ids)), settlements)
      else
        signed(taxed_lines.where(tudla_accounting_entries: { posted_at: @from..@thru }))
      end
    end

    def taxed_lines
      Detail.joins(:entry).where(organization_type: @organization.class.name, organization_id: @organization.id).where.not(tax_code_id: nil)
    end

    # Signed totals of the lines in a scope.
    def signed(scope)
      scope.group(:tax_code_id, :tax_role, :tally).sum(:amount_cents).each_with_object(Hash.new(0)) do |((code_id, role, tally), cents), totals|
        totals[[ code_id, role ]] += (tally == Detail::TALLY_CREDIT) == sales_code_ids.include?(code_id) ? cents : -cents
      end
    end

    def add(first, second)
      second.each_with_object(first.dup) { |(key, cents), sum| sum[key] += cents }
    end

    def sales_code_ids
      @sales_code_ids ||= TaxCode.where(organization: @organization, kind: :sales).pluck(:id).to_set
    end

    # Taxed entries whose tax counts as they are settled: those that opened a receivable,
    # payable or credit, and reversals of those.
    def settled_entry_ids
      @settled_entry_ids ||= begin
        taxed = taxed_lines.distinct.pluck(:entry_id)
        opened = CarryingAmount.joins(:detail).where(tudla_accounting_details: { entry_id: taxed }).distinct.pluck("tudla_accounting_details.entry_id")
        reversals = Entry.where(id: taxed, related_type: Entry.name, related_id: opened).where("particulars LIKE ?", "#{Entry::REVERSAL_PREFIX}%").pluck(:id)
        opened + reversals
      end
    end

    # The tax recognized by allocations made (or taken off) in the span: for each side
    # with taxed lines, its signed totals times the share of it the allocation settled.
    def settlements
      allocations = Allocation.where(organization: @organization).includes(from: [ :forex, { detail: :foreign_exchange } ], to: [ :forex, { detail: :foreign_exchange } ])
      made = allocations.where(allocated_at: @from..@thru)
      taken_off = allocations.where(reversed_at: @from..@thru)
      entry_totals = signed_by_entry((made + taken_off).flat_map { |allocation| [ allocation.from, allocation.to ] }.map { |side| side.detail.entry_id }.uniq)

      [ [ made, 1 ], [ taken_off, -1 ] ].each_with_object(Hash.new(0)) do |(scope, sign), recognized|
        scope.each do |allocation|
          [ allocation.from, allocation.to ].each do |side|
            entry_totals.fetch(side.detail.entry_id, {}).each do |key, cents|
              recognized[key] += sign * (BigDecimal(cents) * share(allocation, side)).round(0, TudlaAccounting.configuration.rounding).to_i
            end
          end
        end
      end
    end

    # { entry_id => { [tax_code_id, role] => signed cents } } for the taxed entries given.
    def signed_by_entry(entry_ids)
      taxed_lines.where(entry_id: entry_ids).group_by(&:entry_id).transform_values do |lines|
        lines.each_with_object(Hash.new(0)) do |line, totals|
          totals[[ line.tax_code_id, line.tax_role ]] += line.credit? == sales_code_ids.include?(line.tax_code_id) ? line.amount_cents : -line.amount_cents
        end
      end
    end

    # The part of a side's opening amount an allocation settled: by its foreign amount when
    # both are foreign, else by its amount in the organization's currency.
    def share(allocation, side)
      opening_foreign = side.forex && side.opening_foreign_cents
      if allocation.other_currency_cents && opening_foreign&.positive?
        BigDecimal(allocation.other_currency_cents) / opening_foreign
      else
        BigDecimal(allocation.amount_cents) / side.detail.amount_cents
      end
    end

    def money(cents)
      Money.new(cents, @organization.currency)
    end
  end
end
