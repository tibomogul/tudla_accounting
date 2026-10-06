module TudlaAccounting
  module ActivityHelper
    ACTIVITY_KINDS = { "entry" => "Entries", "account" => "Accounts", "period" => "Periods",
                       "opening_balances" => "Opening balances", "balances" => "Balance rebuilds",
                       "allocation" => "Payments applied", "tax_code" => "Tax codes",
                       "bank_statement" => "Statement imports", "bank_line" => "Bank matches",
                       "dimension" => "Dimensions", "dimension_value" => "Dimension values" }.freeze

    # What an audit event did, in words, linking to its subject while it still exists.
    def activity_description(event)
      subject = activity_subject_link(event)
      details = event.details
      case event.action
      when "entry.posted" then safe_join([ "Posted ", subject ])
      when "entry.reversed" then safe_join([ "Reversed ", subject, " on #{tc_date(details['on'])}" ])
      when "entry.deleted" then safe_join([ "Deleted the draft ", subject ])
      when "account.created" then safe_join([ "Added the account ", subject ])
      when "account.updated" then safe_join([ "Changed ", subject, ": #{details.fetch('changes', {}).keys.map(&:humanize).join(', ').downcase}" ])
      when "account.deleted" then safe_join([ "Deleted the account ", subject ])
      when "period.created" then safe_join([ "Created the financial year ", subject ])
      when "period.deleted" then safe_join([ "Deleted the financial year ", subject ])
      when "period.closed" then safe_join([ "Closed ", subject ])
      when "period.reopened" then safe_join([ "Reopened ", subject, ": “#{details['reason']}”" ])
      when "opening_balances.saved" then "Saved the opening balances at #{tc_date(details['date'])}"
      when "allocation.created" then safe_join([ "Applied ", subject ])
      when "allocation.reversed" then safe_join([ "Took off ", subject ])
      when "tax_code.created" then safe_join([ "Added the tax code ", subject ])
      when "tax_code.updated" then safe_join([ "Changed ", subject, ": #{details.fetch('changes', {}).keys.map(&:humanize).join(', ').downcase}" ])
      when "tax_code.deleted" then safe_join([ "Deleted the tax code ", subject ])
      when "bank_statement.imported" then safe_join([ "Imported a statement for ", subject, ": #{pluralize(details['imported'], 'line')} new, #{details['skipped']} already there" ])
      when "bank_line.matched" then safe_join([ "Matched the statement line ", subject ])
      when "bank_line.unmatched" then safe_join([ "Unmatched the statement line ", subject ])
      when "dimension.created" then safe_join([ "Added the dimension ", subject ])
      when "dimension_value.created" then safe_join([ "Added ", subject ])
      when "dimension.updated", "dimension_value.updated"
        safe_join([ "Changed ", subject, ": #{details.fetch('changes', {}).keys.map(&:humanize).join(', ').downcase}" ])
      when "balances.rebuilt" then "Rebuilt the balances: #{pluralize(details['corrected'], 'balance')} corrected"
      end
    end

    def activity_kind_options
      [ [ "Everything", "" ] ] + ActivityController.kinds.map { |kind| [ ACTIVITY_KINDS.fetch(kind), kind ] }
    end

    def activity_time(event)
      event.created_at.in_time_zone(TudlaAccounting.configuration.time_zone).strftime("%-d %b %Y %H:%M")
    end

    private

    # { [type, id] => record } for the subjects of the events on the page that still exist,
    # loaded with a query per type (set by ActivityController, or worked out here).
    def activity_subjects
      @activity_subjects ||= ActivityHelper.load_subjects(@page.records)
    end

    LINKED_SUBJECTS = { "TudlaAccounting::Allocation" => { from: :detail } }.freeze

    def self.load_subjects(events)
      events.group_by(&:subject_type).except(nil).flat_map do |type, of_type|
        model = type.safe_constantize
        next [] unless model && model <= ApplicationRecord

        model.where(id: of_type.map(&:subject_id)).includes(LINKED_SUBJECTS.fetch(type, [])).to_a
      end.index_by { |record| [ record.class.name, record.id ] }
    end

    def activity_subject_link(event)
      subject = activity_subjects[[ event.subject_type, event.subject_id ]]
      path = case subject
      when Entry then entry_path(subject)
      when Account then account_path(subject)
      when Period then period_path(subject.root_id)
      when BankStatementLine then banking_account_path(subject.account_id, show: "all")
      when Dimension then edit_dimension_path(subject)
      when DimensionValue then edit_dimension_dimension_value_path(subject.dimension_id, subject)
      when TaxCode then edit_tax_code_path(subject)
      when Allocation then entry_path(subject.from.detail.entry_id)
      end
      path ? link_to(event.subject_label, path, class: "underline") : event.subject_label.to_s
    end
  end
end
