require 'rails_helper'

RSpec.describe "Solid Infrastructure Integration", type: :request do
  it "uses Solid Cache for caching" do
    initial_count = SolidCache::Entry.count

    Rails.cache.write("engine_test_key", "solid_value")
    expect(Rails.cache.read("engine_test_key")).to eq("solid_value")

    # Verification: Check if an entry was persisted in the SQL database
    expect(SolidCache::Entry.count).to be > initial_count
  end

  it "enqueues jobs to Solid Queue" do
    stub_const("TestInlineJob", Class.new(ActiveJob::Base) do
      self.queue_adapter = :solid_queue
      def perform; end
    end)

    expect {
      TestInlineJob.perform_later
    }.to change { SolidQueue::Job.count }.by(1)
  end
end
