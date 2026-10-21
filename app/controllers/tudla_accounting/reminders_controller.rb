module TudlaAccounting
  # The overdue invoices whose reminders are due (see ReminderRunner), and sending them
  # all, as the scheduled job would (:post).
  class RemindersController < ApplicationController
    permits :post, only: :create

    def index
      @reminders = ReminderRunner.due(organization: accounting_organization)
    end

    def create
      result = ReminderRunner.call(organization: accounting_organization)
      flash[:notice] = result.sent.any? ? "Emailing #{helpers.pluralize(result.sent.size, 'reminder')}." : ("No reminders are due." if result.no_address.empty?)
      flash[:alert] = ("Not reminded, as they have no email address: #{result.no_address.map { |reminder| reminder.invoice.contact.name }.uniq.to_sentence}." if result.no_address.any?)
      redirect_to reminders_path
    end
  end
end
