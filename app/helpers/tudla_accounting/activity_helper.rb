module TudlaAccounting
  module ActivityHelper
    ACTIVITY_KINDS = { "entry" => "Entries", "account" => "Accounts", "period" => "Periods",
                       "opening_balances" => "Opening balances", "balances" => "Balance rebuilds",
                       "allocation" => "Payments applied", "tax_code" => "Tax codes" }.freeze

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

    def activity_subject_link(event)
      path = case event.subject_type
      when Entry.name then (entry_path(event.subject_id) if Entry.exists?(event.subject_id))
      when Account.name then (account_path(event.subject_id) if Account.exists?(event.subject_id))
      when Period.name then (period_path(Period.find(event.subject_id).root) if Period.exists?(event.subject_id))
      when TaxCode.name then (edit_tax_code_path(event.subject_id) if TaxCode.exists?(event.subject_id))
      when Allocation.name then entry_path(Allocation.find(event.subject_id).from.detail.entry_id)
      end
      path ? link_to(event.subject_label, path, class: "underline") : event.subject_label.to_s
    end
  end
end
