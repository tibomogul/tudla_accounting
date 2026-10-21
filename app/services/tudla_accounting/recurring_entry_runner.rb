# frozen_string_literal: true

module TudlaAccounting
  # Makes the entries recurring entries have due by a date (today by default, in the
  # configured time zone), catching up any missed: each as a draft, or posted when the
  # template says so. RecurringEntriesJob runs it for every organization; the host app
  # schedules that job (daily, say).
  #
  #   RecurringEntryRunner.call(organization: org, as_of: Date.new(2026, 11, 1))
  #   # => #<Result created=[entry, ...] posted=[entry, ...] problems=["Rent: 1 Nov 2026: ..."]>
  #
  # Each template is locked while it runs, and each entry's idempotency key names the
  # template and date, so runs that overlap make each entry once. A template whose entry
  # can't be made (an account made inactive since, say) stops there and keeps the reason
  # in last_problem, to be tried again next run; an entry that can't be posted (its month
  # closed, no year for it) is left as a draft, the reason kept too.
  class RecurringEntryRunner
    Result = Struct.new(:created, :posted, :problems, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(organization: nil, as_of: nil)
      @organization = organization
      @as_of = as_of || ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone].today
      @result = Result.new(created: [], posted: [], problems: [])
    end

    def call
      due = RecurringEntry.active.where(next_on: ..@as_of)
      due = due.where(organization: @organization) if @organization
      due.order(:next_on, :id).each { |template| run(template) }
      @result
    end

    private

    def run(template)
      template.with_lock do
        while template.due?(@as_of)
          on = template.next_on
          made, problem = make(template, on)
          break unless made

          template.advance!(on, problem: problem)
        end
      end
    end

    # [entry made?, why it was left as a draft (or nil)] for the entry on a date, posted if
    # the template says so. One that can't be made keeps the template where it is.
    def make(template, on)
      entry = Entry.transaction(requires_new: true) { Entry.create_from_ruby_hash(template.entry_hash(on: on)) }
      @result.created << entry
      AuditEvent.record!("recurring_entry.generated", organization: template.organization, subject: template, details: { entry_id: entry.id, on: on.iso8601 })
      [ true, (post(template, entry, on) if template.post_automatically? && entry.draft?) ]
    rescue ArgumentError, ActiveRecord::RecordInvalid => e
      template.update_columns(last_problem: problem(template, on, e.message))
      [ false, nil ]
    end

    # Posts the entry; the problem when it can't be.
    def post(template, entry, on)
      Entry.transaction(requires_new: true) { entry.post(entry.transacted_at) }
      @result.posted << entry
      nil
    rescue ArgumentError => e
      problem(template, on, "left as a draft: #{e.message}")
    end

    def problem(template, on, message)
      text = "#{on.strftime('%-d %b %Y')}: #{message}"
      @result.problems << "#{template.name}: #{text}"
      text
    end
  end
end
