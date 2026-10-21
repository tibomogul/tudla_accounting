# frozen_string_literal: true

module TudlaAccounting
  # A tax return form's figures for a span of time, box by box from the top:
  #
  #   TaxReturnCalculator.call(form, from: march.from_date, thru: may.thru_date, basis: :cash)
  #   # => { boxes: [#<Box box=G1 amount=$11,000 parts=[#<Part part=... amount=$11,000>]>, ...], basis:, from:, thru: }
  #
  # Tax code parts take the tax summary's figures (TaxReport, on the basis given or the
  # tax_basis setting): a code's net amount, its tax, or the two together, positive for
  # sales on a sales code and purchases on a purchases code. Account parts take the
  # account's movement (its sub-accounts' included) from what was posted in the span, on
  # its natural side, whatever the basis. Box parts take an earlier box's figure as
  # reported, so after its cents were dropped. A box in whole units drops its cents
  # (towards zero).
  class TaxReturnCalculator
    Box = Struct.new(:box, :amount, :parts, keyword_init: true)
    Part = Struct.new(:part, :amount, keyword_init: true)

    def self.call(...) = new(...).call

    def initialize(form, from:, thru:, basis: nil)
      @form = form
      @organization = form.organization
      @from = from
      @thru = thru
      @basis = basis
    end

    def call
      report = TaxReport.call(@organization, from: @from, thru: @thru, basis: @basis)
      @codes = report[:codes].index_by { |row| row[:tax_code].id }
      figures = {}
      boxes = @form.boxes.includes(parts: %i[tax_code account from_box]).map do |box|
        parts = box.parts.map { |part| Part.new(part: part, amount: value(part, figures) * part.sign) }
        amount = parts.sum(money(0)) { |part| part.amount }
        amount = whole(amount) if box.whole_units?
        figures[box.id] = amount
        Box.new(box: box, amount: amount, parts: parts)
      end
      { boxes: boxes, basis: report[:basis], from: @from, thru: @thru }
    end

    private

    def value(part, figures)
      case part.source
      when "account" then movement(part.account)
      when "box" then figures.fetch(part.from_box_id)
      else
        row = @codes[part.tax_code_id]
        return money(0) unless row

        { "tax_code_base" => row[:base], "tax_code_tax" => row[:tax], "tax_code_gross" => row[:base] + row[:tax] }.fetch(part.source)
      end
    end

    # What was posted to the account and those beneath it in the span, on its natural side.
    def movement(account)
      sums = Detail.joins(:entry).where(account_id: account.subtree_ids, tudla_accounting_entries: { posted_at: @from..@thru }).group(:tally).sum(:amount_cents)
      debits = sums.fetch(Detail::TALLY_DEBIT, 0) - sums.fetch(Detail::TALLY_CREDIT, 0)
      money(account.debit_balance? ? debits : -debits)
    end

    def whole(amount)
      unit = 10**Money::Currency.new(@organization.currency).exponent
      money(amount.cents.abs / unit * unit * (amount.negative? ? -1 : 1))
    end

    def money(cents)
      Money.new(cents, @organization.currency)
    end
  end
end
