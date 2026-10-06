module TudlaAccounting
  class EntriesController < ApplicationController
    permits :record, only: %i[new create edit update destroy]
    permits :post, only: %i[post reverse]

    before_action :set_entry, only: %i[show edit update destroy post reverse]
    before_action :require_draft, only: %i[edit update destroy]
    helper_method :organization_accounts

    def index
      entries = organization_scope(Entry).includes(:details).order(transacted_at: :desc, id: :desc)
      entries = entries.where("particulars ILIKE ?", "%#{Entry.sanitize_sql_like(params[:q])}%") if params[:q].present?
      entries = entries.where(posted_at: nil) if params[:status] == "draft"
      entries = entries.where.not(posted_at: nil) if params[:status] == "posted"
      entries = entries.where(transacted_at: day_start(params[:from])..) if params[:from].present?
      entries = entries.where(transacted_at: ...day_start(params[:thru]) + 1.day) if params[:thru].present?
      if params[:account_id].present?
        account = organization_scope(Account).find(params[:account_id])
        entries = entries.where(id: Detail.where(account_id: account.subtree_ids).select(:entry_id))
      end
      @page = Paginator.new(entries, page: params[:page])
    end

    def show
    end

    def new
      @entry = organization_scope(Entry).new(transacted_at: day_start(Date.current))
      2.times { @entry.details.build }
    end

    def create
      attributes, problems = entry_attributes
      @entry = organization_scope(Entry).new(attributes)
      if problems.empty? && @entry.save
        redirect_to entry_path(@entry), notice: "Draft entry saved. Post it to update the balances."
      else
        show_problems(problems)
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      attributes, problems = entry_attributes
      @entry.assign_attributes(attributes)
      if problems.empty? && @entry.save
        redirect_to entry_path(@entry), notice: "Draft entry saved."
      else
        show_problems(problems)
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @entry.destroy!
      redirect_to entries_path, notice: "Draft entry deleted."
    end

    def post
      @entry.post(@entry.transacted_at)
      redirect_to entry_path(@entry), notice: "Entry posted."
    rescue ArgumentError => e
      redirect_to entry_path(@entry), alert: "The entry could not be posted: #{posting_problem(e)}."
    end

    def reverse
      on = params[:on].presence&.to_date || Date.current
      reversal = @entry.reverse!(on: on)
      redirect_to entry_path(reversal), notice: "Entry reversed on #{helpers.tc_date(on)}."
    rescue ArgumentError => e
      redirect_to entry_path(@entry), alert: "The entry could not be reversed: #{posting_problem(e)}."
    end

    private

    def organization_accounts
      organization_scope(Account).order(:code)
    end

    def set_entry
      @entry = organization_scope(Entry).includes(details: %i[account foreign_exchange carrying_amount]).find(params[:id])
    end

    def require_draft
      redirect_to entry_path(@entry), alert: "A posted entry can't be changed; reverse it instead." if @entry.posted?
    end

    def day_start(date)
      date = date.to_date
      ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone].local(date.year, date.month, date.day)
    end

    # The form's lines, with separate debit and credit columns, as detail attributes, and
    # anything wrong with them that the model can't tell (e.g. both columns filled in).
    def entry_attributes
      permitted = params.require(:entry).permit(:particulars, :transacted_at, lines: %i[id account_id debit credit _destroy])
      currency = accounting_organization.currency
      problems = []
      rows = permitted.fetch(:lines, {}).to_h.values
      lines = rows.each_with_index.filter_map do |line, index|
        next if line[:id].blank? && line.values_at(:account_id, :debit, :credit).all?(&:blank?) # an unused blank row

        debit = amount_cents(line[:debit], currency) { problems << "Line #{index + 1}: #{line[:debit]} isn't an amount" }
        credit = amount_cents(line[:credit], currency) { problems << "Line #{index + 1}: #{line[:credit]} isn't an amount" }
        problems << "Line #{index + 1} has both a debit and a credit; use one line for each" if debit && credit && line[:_destroy] != "1"

        { id: line[:id].presence, _destroy: line[:_destroy],
          account_id: (organization_scope(Account).find(line[:account_id]).id if line[:account_id].present?),
          tally: (credit && !debit ? Detail::TALLY_CREDIT : Detail::TALLY_DEBIT),
          amount_cents: (debit || credit).to_i, currency: currency }.compact
      end

      attributes = { particulars: permitted[:particulars], details_attributes: lines,
                     transacted_at: (day_start(permitted[:transacted_at]) if permitted[:transacted_at].present?) }
      [ attributes, problems ]
    end

    # Cents for a typed amount ("1,234.50"), nil when blank; yields when it isn't a number.
    def amount_cents(text, currency)
      text = text.to_s.strip.delete(",")
      return nil if text.empty?

      Money.from_amount(BigDecimal(text), currency).cents
    rescue ArgumentError
      yield
      nil
    end

    def show_problems(problems)
      @entry.valid?
      problems.each { |problem| @entry.errors.add(:base, problem) }
    end

    def posting_problem(error)
      { "no valid period found for the posted date" => "no financial year covers its date",
        "the period for the posted date is closed" => "its month is closed" }.fetch(error.message, error.message.downcase_first)
    end
  end
end
