module TudlaAccounting
  # The audit trail: who did what to the books, newest first.
  class ActivityController < ApplicationController
    def index
      @kind = params[:kind].presence_in(ActivityController.kinds)
      events = organization_scope(AuditEvent).newest_first
      events = events.where("action LIKE ?", "#{@kind}.%") if @kind
      @page = Paginator.new(events, page: params[:page])
    end

    # "entry", "account", ... the subjects actions are grouped by.
    def self.kinds
      AuditEvent::ACTIONS.map { |action| action.split(".").first }.uniq
    end
  end
end
