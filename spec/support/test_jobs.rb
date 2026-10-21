# Runs an example's jobs on Active Job's test adapter (the dummy app queues them in Solid
# Queue), so it can see what was queued and run it (perform_enqueued_jobs).
RSpec.shared_context "with the test job adapter" do
  include ActiveJob::TestHelper

  around do |example|
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    ActiveJob::Base.queue_adapter = original
  end
end
