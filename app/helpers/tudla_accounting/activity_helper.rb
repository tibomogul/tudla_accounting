module TudlaAccounting
  module ActivityHelper
    ACTIVITY_KINDS = { "entry" => "Entries", "account" => "Accounts", "period" => "Periods",
                       "opening_balances" => "Opening balances", "balances" => "Balance rebuilds",
                       "allocation" => "Payments applied", "tax_code" => "Tax codes",
                       "bank_statement" => "Statement imports", "bank_line" => "Bank matches",
                       "dimension" => "Dimensions", "dimension_value" => "Dimension values",
                       "recurring_entry" => "Recurring entries", "bank_rule" => "Bank rules",
                       "budget" => "Budgets", "tax_return_form" => "Tax returns", "tax_return" => "Tax returns filed",
                       "contact" => "Contacts", "document" => "Invoices and bills", "payment" => "Payments", "api_token" => "API tokens", "email" => "Emails" }.freeze

    # What an audit event did, in words, linking to its subject while it still exists.
    def activity_description(event)
      subject = activity_subject_link(event)
      details = event.details
      case event.action
      when "entry.posted" then safe_join([ "Posted ", subject ])
      when "entry.reversed" then safe_join([ "Reversed ", subject, " on #{tc_date(details['on'])}" ])
      when "entry.deleted" then safe_join([ "Deleted the draft ", subject ])
      when "entry.attachment_added" then safe_join([ "Attached #{details['filename']} to ", subject ])
      when "entry.attachment_removed"
        safe_join([ "Removed #{details['filename']} from ", subject, (": “#{details['reason']}”" if details["reason"]) ].compact)
      when "account.created" then safe_join([ "Added the account ", subject ])
      when "account.updated" then safe_join([ "Changed ", subject, ": #{details.fetch('changes', {}).keys.map(&:humanize).join(', ').downcase}" ])
      when "account.deleted" then safe_join([ "Deleted the account ", subject ])
      when "account.deactivated"
        safe_join([ "Made ", subject, " inactive", (" with #{details['sub_accounts'].to_sentence}" if details["sub_accounts"].present?) ].compact)
      when "account.reactivated" then safe_join([ "Reactivated ", subject ])
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
      when "recurring_entry.created" then safe_join([ "Added the recurring entry ", subject ])
      when "recurring_entry.updated" then safe_join([ "Changed the recurring entry ", subject, ": #{details.fetch('changes', {}).keys.map(&:humanize).join(', ').downcase}" ])
      when "recurring_entry.deleted" then safe_join([ "Deleted the recurring entry ", subject ])
      when "recurring_entry.generated" then safe_join([ "Made the entry for #{tc_date(details['on'])} from ", subject ])
      when "bank_rule.created" then safe_join([ "Added the bank rule ", subject ])
      when "bank_rule.updated" then safe_join([ "Changed the bank rule ", subject, ": #{details.fetch('changes', {}).keys.map(&:humanize).join(', ').downcase}" ])
      when "bank_rule.deleted" then safe_join([ "Deleted the bank rule ", subject ])
      when "budget.created" then safe_join([ "Added the budget ", subject ])
      when "budget.updated"
        if details["accounts"]
          codes = details["accounts"]
          safe_join([ "Changed the amounts of #{codes.first(5).join(', ')}#{" and #{codes.size - 5} more" if codes.size > 5} in the budget ", subject ])
        else
          safe_join([ "Changed the budget ", subject, ": #{details.fetch('changes', {}).keys.map(&:humanize).join(', ').downcase}" ])
        end
      when "budget.deleted" then safe_join([ "Deleted the budget ", subject ])
      when "tax_return_form.created" then safe_join([ "Added the tax return ", subject ])
      when "tax_return_form.updated"
        if details["box"]
          safe_join([ "#{details['change'].capitalize} the box #{details['box']} of the tax return ", subject ])
        else
          safe_join([ "Changed the tax return ", subject, ": #{details.fetch('changes', {}).keys.map(&:humanize).join(', ').downcase}" ])
        end
      when "tax_return_form.deleted" then safe_join([ "Deleted the tax return ", subject ])
      when "contact.created" then safe_join([ "Added the contact ", subject ])
      when "contact.updated" then safe_join([ "Changed the contact ", subject, ": #{details.fetch('changes', {}).keys.map(&:humanize).join(', ').downcase}" ])
      when "contact.deleted" then safe_join([ "Deleted the contact ", subject ])
      when "document.created" then safe_join([ "Drafted ", subject ])
      when "document.updated" then safe_join([ "Changed ", subject, ": #{details.fetch('changes', {}).keys.map { |key| key.delete_suffix('_cents').humanize }.join(', ').downcase}" ])
      when "document.deleted" then safe_join([ "Deleted ", subject ])
      when "document.approved" then safe_join([ "Approved ", subject ])
      when "email.sent" then safe_join([ "Emailed ", *emailed_what(details["kind"], subject), " to #{details['to']}" ])
      when "email.failed" then safe_join([ "Couldn't email ", *emailed_what(details["kind"], subject), " to #{details['to']}: #{details['error']}" ])
      when "api_token.created" then safe_join([ "Issued ", subject, " (#{details['permissions'].to_sentence})" ])
      when "api_token.revoked" then safe_join([ "Revoked ", subject ])
      when "payment.recorded"
        applied = details["documents"].presence
        safe_join([ "Recorded ", subject, (" for #{applied.to_sentence}" if applied) ].compact)
      when "payment.voided" then safe_join([ "Voided ", subject, " on #{tc_date(details['on'])}: “#{details['reason']}”" ])
      when "document.voided" then safe_join([ "Voided ", subject, " on #{tc_date(details['on'])}: “#{details['reason']}”" ])
      when "tax_return.filed" then safe_join([ "Filed the tax return ", subject ])
      when "tax_return.withdrawn" then safe_join([ "Withdrew the tax return ", subject, ": “#{details['reason']}”" ])
      when "balances.rebuilt" then rebuilt_description(details)
      end
    end

    # What an email was, around its subject's link: "Invoice INV-0001 – Northwind",
    # "Northwind's statement", "the receipt for Payment from Northwind of $10.00".
    def emailed_what(kind, subject)
      case kind
      when "statement" then [ subject, "'s statement" ]
      when "receipt" then [ "the receipt for ", subject ]
      when "payment_notice" then [ "the payment notice for ", subject ]
      when "reminder" then [ "a reminder of ", subject ]
      else [ subject ]
      end
    end

    # Which accounts a rebuild corrected. Events from before the accounts were recorded
    # give the count only.
    def rebuilt_description(details)
      text = "Rebuilt the balances: #{pluralize(details['corrected'], 'balance')} corrected"
      text += " (#{details['accounts'].to_sentence})" if details["accounts"].present?
      text
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
      when RecurringEntry then recurring_entry_path(subject)
      when BankRule then edit_bank_rule_path(subject)
      when Budget then budget_path(subject)
      when TaxReturnForm then tax_return_form_path(subject)
      when FiledTaxReturn then filed_tax_return_path(subject)
      when Contact then contact_path(subject)
      when Document then document_path(subject)
      when Payment then payment_path(subject)
      when ApiToken then api_tokens_path
      end
      path ? link_to(event.subject_label, path, class: "underline") : event.subject_label.to_s
    end
  end
end
