module TudlaAccounting
  # Picking the periods a report covers from the request's parameters (period_id, from_id
  # and thru_id, compare), and laying a statement out as a table, for the report pages and
  # the JSON API alike. Needs accounting_organization, organization_scope and helpers.
  module ReportPeriods
    extend ActiveSupport::Concern

    # What a statement can be compared with: the period before, the same period a year
    # earlier, or each month of the year (up to the period chosen).
    COMPARISONS = { "previous" => "Previous period", "last_year" => "Same period last year", "months" => "Each month of the year" }.freeze

    private

    # The statement on the page as a table: its comparison, or the period alone.
    def statement_table(report_class, sections:, figures:)
      comparison = @comparison || Reports::Comparison.new(report_class, accounting_organization, [ @period ])
      if comparison.is_a?(Reports::BudgetComparison)
        groups = helpers.budget_column_groups(comparison)
        return Reports::Tables.statement(comparison, labels: groups.flat_map { |group| [ "#{group} actual", "#{group} budget" ] }, sections: sections, figures: figures,
                                                     change: true, change_headings: groups.map { |group| [ "#{group} variance", "#{group} variance %" ] })
      end
      Reports::Tables.statement(comparison, labels: comparison.periods.map { |period| helpers.comparison_label(period, @compare) },
                                            sections: sections, figures: figures, change: comparison.periods.size == 2 && @compare != "months")
    end

    # "2026-03-01-to-2026-05-31" for the months picked.
    def span_name
      "#{@from.from_date.to_date}-to-#{@thru.thru_date.to_date}"
    end

    # @months, and the run @from..@thru picked with from_id/thru_id (either way round), by
    # default this month, (year_to_date) the start of its year to it, (quarter) its filing
    # quarter, or (last_year) the last financial year ended before it, else as year_to_date.
    # False without months.
    def month_range(year_to_date: false, quarter: false, last_year: false)
      @months = months.reverse
      return false if @months.empty?

      current = @months.find { |month| month.includes_date?(Time.current) }
      default_thru = current || @months.last
      ended = @months.select { |month| month.thru_date < default_thru.from_date && month.root_id != default_thru.root_id }.last if last_year
      default_thru = ended if ended
      default_from = year_to_date || last_year ? @months.find { |month| month.root_id == default_thru.root_id } : default_thru
      if quarter
        span = FilingQuarters.new(accounting_organization).of(default_thru.from_date.to_date)
        within = @months.select { |month| span.range.cover?(month.from_date.to_date) }
        default_from, default_thru = within.first, within.last
      end
      @from = picked_month(:from_id) || default_from
      @thru = picked_month(:thru_id) || (params[:from_id].present? && !year_to_date && !last_year ? @from : default_thru)
      @from, @thru = @thru, @from if @thru.from_date < @from.from_date
      true
    end

    # @quarters, every run of three months in a row the periods cover, latest first, and
    # @quarter, the run picked (with the quarter parameter, its first day), by default this
    # filing quarter, else the latest before it, else the earliest. Nil without such a run.
    def three_months
      runs = months.reverse.each_cons(3).select { |run| run.each_cons(2).all? { |month, following| month.thru_date.to_date + 1 == following.from_date.to_date } }
      @quarters = runs.map { |first, _, last| FilingQuarters::Quarter.new(from: first.from_date.to_date, thru: last.thru_date.to_date) }.reverse
      return @quarter = @quarters.find { |quarter| quarter.from.iso8601 == params[:quarter] } || raise(ActiveRecord::RecordNotFound) if params[:quarter].present?

      filing = FilingQuarters.new(accounting_organization).of(Date.current)
      @quarter = @quarters.find { |quarter| quarter.from == filing.from } || @quarters.find { |quarter| quarter.from < filing.from } || @quarters.last
    end

    # The three-month runs for a select: the filing quarters first, since those are what
    # certificates normally cover, then the others.
    def quarter_choices
      quarters = FilingQuarters.new(accounting_organization)
      filing, others = @quarters.partition { |quarter| quarters.of(quarter.from).from == quarter.from }
      { "Filing quarters" => filing, "Other three months" => others }.reject { |_, group| group.empty? }
                                                                     .transform_values { |group| group.map { |quarter| [ quarter.label, quarter.from.iso8601 ] } }
    end

    def picked_month(param)
      return if params[param].blank?

      @months.find { |month| month.id == params[param].to_i } || raise(ActiveRecord::RecordNotFound)
    end

    def years
      organization_scope(Period).roots.order(from_date: :desc).to_a
    end

    def months
      organization_scope(Period).where.not(ancestry: "/").order(from_date: :desc).to_a.select { |period| period.children_count.zero? }
    end

    def current_year
      Period.periods_for_date(accounting_organization, Time.current).roots.first
    end

    # The period picked (one of the choices), else the default: the one containing today,
    # else the most recent.
    def chosen_period(choices, default: nil)
      @choices = choices
      return choices.find { |period| period.id == params[:period_id].to_i } || raise(ActiveRecord::RecordNotFound) if params[:period_id].present?

      default || choices.find { |period| period.includes_date?(Time.current) } || choices.find { |period| period.from_date <= Time.current } || choices.last
    end

    # The statement for @period beside the periods the compare parameter asks for, or nil
    # when it asks for none or there is nothing to compare with (@compare says what was
    # asked for, so the page can say so).
    def comparison(report_class)
      @compare = params[:compare].presence_in(COMPARISONS.keys)
      return unless @compare

      periods = compared_periods(@period)
      periods.size > 1 ? Reports::Comparison.new(report_class, accounting_organization, periods) : nil
    end

    # Budget vs actual for @period, when the compare parameter asks for a budget: "budget"
    # for the year's main budget (or its first), "budget-<id>" for another of its budgets.
    # Nil, with @compare set, when the year has none.
    def budget_comparison
      match = params[:compare].to_s.match(/\Abudget(?:-(\d+))?\z/)
      return unless match

      @compare = "budget"
      @budget = @budgets.find { |budget| budget.id == match[1].to_i } || @budgets.first
      @budget && Reports::BudgetComparison.new(@budget, @period)
    end

    # The columns, the chosen period's among them. Beside the previous period or the same
    # one a year earlier (of the same kind: months beside a month, years beside a year),
    # the chosen period comes first. For each month, the months of its year in order, up
    # to the chosen month, or all of them and then the year as a whole when a year was
    # chosen (its total).
    def compared_periods(period)
      peers = organization_scope(Period).at_depth(period.depth).to_a
      case @compare
      when "previous" then [ period, peers.select { |peer| peer.thru_date < period.from_date }.max_by(&:from_date) ].compact
      when "last_year" then [ period, peers.find { |peer| peer.from_date.to_date == period.from_date.to_date.prev_year } ].compact
      when "months"
        year = period.root
        in_year = year.children.order(:from_date).to_a
        period.root? ? [ *in_year, year ] : in_year.select { |month| month.from_date <= period.from_date }
      end
    end
  end
end
