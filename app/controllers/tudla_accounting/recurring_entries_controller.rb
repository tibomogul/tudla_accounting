module TudlaAccounting
  # Recurring entries: their templates and schedules, making the entries due now, and a
  # one-off draft from a template.
  class RecurringEntriesController < ApplicationController
    permits :record, only: %i[new create edit update destroy make]
    permits :post, only: :run # a template may post its entries

    before_action :set_recurring_entry, only: %i[show edit update destroy make]

    def index
      @recurring_entries = organization_scope(RecurringEntry).includes(lines: :account).order(:name).to_a
      @today = today
      @due = @recurring_entries.select { |template| template.due?(@today) }
    end

    def show
      @entries = Entry.where(source: @recurring_entry).includes(:details).order(transacted_at: :desc, id: :desc).limit(24)
    end

    # A new template, or (entry_id) one copying an entry's particulars and lines.
    def new
      @recurring_entry = organization_scope(RecurringEntry).new(frequency: "monthly", interval: 1, day_of_month: 1,
                                                                starts_on: today.next_month.beginning_of_month)
      if params[:entry_id].present?
        copy_entry(organization_scope(Entry).includes(details: :tags).find(params[:entry_id]))
      else
        2.times { @recurring_entry.lines.build }
      end
    end

    def create
      attributes, problems = template_attributes
      @recurring_entry = organization_scope(RecurringEntry).new(attributes)
      if problems.empty? && @recurring_entry.save
        redirect_to recurring_entry_path(@recurring_entry), notice: "Recurring entry saved. #{next_notice}"
      else
        problems.each { |problem| @recurring_entry.errors.add(:base, problem) }
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      attributes, problems = template_attributes
      @recurring_entry.assign_attributes(attributes)
      if problems.empty? && @recurring_entry.save
        redirect_to recurring_entry_path(@recurring_entry), notice: "Recurring entry saved. #{next_notice}"
      else
        problems.each { |problem| @recurring_entry.errors.add(:base, problem) }
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @recurring_entry.destroy!
      redirect_to recurring_entries_path, notice: "Recurring entry #{@recurring_entry.name} deleted. The entries made from it stay."
    end

    # Makes the entries due by today, as the scheduled job would.
    def run
      result = RecurringEntryRunner.call(organization: accounting_organization, as_of: today)
      made = result.created.size
      flash[:notice] = made.zero? ? "No entries were due." : "Made #{helpers.pluralize(made, 'entry')}, #{result.posted.size} of them posted."
      flash[:alert] = "Some couldn't be made or posted: #{result.problems.to_sentence}." if result.problems.any?
      redirect_to recurring_entries_path
    end

    # A draft for today from the template, apart from its schedule.
    def make
      entry = Entry.create_from_ruby_hash(@recurring_entry.entry_hash(on: today).merge(idempotency_key: nil))
      redirect_to entry_path(entry), notice: "Draft made from #{@recurring_entry.name}. Post it, or edit it first."
    rescue ArgumentError, ActiveRecord::RecordInvalid => e
      redirect_to recurring_entry_path(@recurring_entry), alert: "No draft was made: #{e.message.downcase_first}."
    end

    private

    def set_recurring_entry
      @recurring_entry = organization_scope(RecurringEntry).find(params[:id])
    end

    def today
      ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone].today
    end

    def next_notice
      @recurring_entry.next_on ? "The next entry is due on #{helpers.tc_date(@recurring_entry.next_on)}." : "Its schedule has run out."
    end

    # The entry's own lines (its tax lines are worked out again from the taxed ones).
    def copy_entry(entry)
      @recurring_entry.assign_attributes(name: entry.particulars.truncate(60), particulars: entry.particulars, reference: entry.reference)
      entry.details.reject(&:tax_tax?).each do |detail|
        @recurring_entry.lines.build(account_id: detail.account_id, tally: detail.tally, amount_cents: detail.amount_cents, description: detail.description,
                                     tax_code_id: detail.tax_code_id, dimension_value_ids: detail.tags.map(&:dimension_value_id))
      end
    end

    # The form's fields and lines (debit and credit columns, as the entry form has) as the
    # template's attributes, and anything wrong with the lines the model can't tell.
    def template_attributes
      permitted = params.require(:recurring_entry).permit(:name, :particulars, :reference, :frequency, :interval, :day_of_month, :starts_on, :ends_on,
                                                          :occurrences_limit, :post_automatically, :reverse_next_month, :active, :tax_inclusive,
                                                          lines: [ :id, :account_id, :debit, :credit, :description, :tax_code_id, :_destroy, { dimensions: {} } ])
      problems = []
      currency = accounting_organization.currency
      lines = permitted.fetch(:lines, {}).to_h.values.each_with_index.filter_map do |line, index|
        next if line[:id].blank? && line.values_at(:account_id, :debit, :credit, :description).all?(&:blank?)

        debit = amount_cents(line[:debit], currency) { problems << "Line #{index + 1}: #{line[:debit]} isn't an amount" }
        credit = amount_cents(line[:credit], currency) { problems << "Line #{index + 1}: #{line[:credit]} isn't an amount" }
        problems << "Line #{index + 1} has both a debit and a credit; use one line for each" if debit && credit && line[:_destroy] != "1"
        { id: line[:id].presence, _destroy: line[:_destroy] }.compact.merge( # a blank tax code or description clears it
          account_id: (organization_scope(Account).find(line[:account_id]).id if line[:account_id].present?),
          tally: (credit && !debit ? "credit" : "debit"), amount_cents: (debit || credit).to_i, description: line[:description],
          tax_code_id: (organization_scope(TaxCode).find(line[:tax_code_id]).id if line[:tax_code_id].present?),
          dimension_value_ids: dimension_value_ids(line)
        )
      end
      attributes = permitted.except(:lines).to_h.merge(lines_attributes: lines)
      attributes[:day_of_month] = nil if attributes[:day_of_month] == "last"
      [ attributes, problems ]
    end
  end
end
