require "rails_helper"

RSpec.describe "TudlaAccounting events" do
  let(:organization) { create(:organization) }
  let(:received) { [] }
  let(:subscribers) { [] }

  after { subscribers.each { |subscriber| ActiveSupport::Notifications.unsubscribe(subscriber) } }

  def listen(action = nil) = subscribers << TudlaAccounting.subscribe(action) { |event| received << event }

  it "publishes each recorded action once it commits" do
    listen("period.created")
    year = TudlaAccounting::PeriodCreator.call(organization, 2026)

    expect(received.map { |event| [ event.class, event.action, event.subject ] }).to eq([ [ TudlaAccounting::AuditEvent, "period.created", year ] ])
  end

  it "publishes nothing for a change that is rolled back" do
    listen
    ActiveRecord::Base.transaction do
      TudlaAccounting::PeriodCreator.call(organization, 2026)
      raise ActiveRecord::Rollback
    end
    expect(received).to be_empty
  end

  it "publishes every action to a subscriber that names none" do
    listen
    year = TudlaAccounting::PeriodCreator.call(organization, 2026)
    year.children.order(:from_date).first.close!
    expect(received.map(&:action)).to eq(%w[period.created period.closed])
  end

  it "refuses an unknown action" do
    expect { TudlaAccounting.subscribe("entry.posed") { nil } }.to raise_error(ArgumentError, /unknown event "entry.posed"; expected one of entry.posted/)
  end
end
