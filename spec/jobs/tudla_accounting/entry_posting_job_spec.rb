require "rails_helper"

RSpec.describe TudlaAccounting::EntryPostingJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers
  let(:organization) { create(:organization) }
  let(:cash) { create(:tudla_accounting_account, code: "1000", category: :asset, organization: organization) }
  let(:capital) { create(:tudla_accounting_account, code: "3000", category: :equity, organization: organization) }

  def unposted_entry(org = organization, transacted_at: Time.zone.local(2026, 3, 10, 9))
    entry = build(:tudla_accounting_entry, organization: org, particulars: "Investment", transacted_at: transacted_at)
    entry.details.build(account: cash, tally: :debit, amount_cents: 100_00, currency: "USD", organization: org)
    entry.details.build(account: capital, tally: :credit, amount_cents: 100_00, currency: "USD", organization: org)
    entry.tap(&:save!)
  end

  describe "#perform" do
    let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
    let(:march) { year.children.order(:from_date).third }

    it "posts the entry into the period of its transacted_at, whenever the job runs" do
      entry = unposted_entry(transacted_at: Time.zone.local(2026, 3, 28, 17))

      travel_to(Time.zone.local(2026, 4, 2, 9)) { described_class.perform_now(entry.id) }

      expect(entry.reload.posted_at).to eq(Time.zone.local(2026, 3, 28, 17))
      expect(entry.details.map { |detail| detail.balance.period }).to all(eq(march))
    end

    it "leaves an already-posted entry alone" do
      entry = unposted_entry
      entry.post(Time.zone.local(2026, 3, 10, 9))

      expect { described_class.perform_now(entry.id) }.not_to change { entry.reload.posted_at }
      expect(TudlaAccounting::Balance.find_by(account: cash, period: year).current_amount_cents).to eq(100_00) # posted once
    end

    it "does nothing for a missing entry" do
      expect { described_class.perform_now(0) }.not_to raise_error
    end

    it "logs and discards a failure, leaving the entry unposted" do
      entry = unposted_entry(transacted_at: Time.zone.local(2030, 1, 1)) # no period covers 2030
      allow(Rails.logger).to receive(:error)

      described_class.perform_now(entry.id)

      expect(entry.reload.posted_at).to be_nil
      expect(Rails.logger).to have_received(:error).with(/EntryPostingJob failed and will not be retried: no valid period found/)
    end

    it "logs and discards an entry without a transacted_at" do
      entry = unposted_entry(transacted_at: nil)
      allow(Rails.logger).to receive(:error)

      described_class.perform_now(entry.id)

      expect(entry.reload.posted_at).to be_nil
      expect(Rails.logger).to have_received(:error).with(/posted_at must be a datetime/)
    end
  end

  describe "queueing" do
    it "uses the entry_posting queue" do
      expect(described_class.new.queue_name).to eq("entry_posting")
    end

    it "keys its concurrency limit on the entry's organization" do
      entry = unposted_entry
      expect(described_class.concurrency_key_for(entry.id)).to eq("Organization/#{organization.id}")
      expect(described_class.concurrency_key_for(0)).to eq("unknown")
    end

    it "lets only one posting job per organization run at a time" do
      other_org = create(:organization)
      first, second = unposted_entry, unposted_entry
      other = unposted_entry(other_org)

      jobs = [ first, second, other ].map { |entry| described_class.perform_later(entry.id) }
      solid_jobs = SolidQueue::Job.where(active_job_id: jobs.map(&:job_id)).index_by(&:active_job_id)

      expect(solid_jobs[jobs[0].job_id].ready_execution).to be_present
      expect(solid_jobs[jobs[1].job_id].blocked_execution).to be_present
      expect(solid_jobs[jobs[2].job_id].ready_execution).to be_present
    ensure
      SolidQueue::Job.where(active_job_id: jobs.to_a.map(&:job_id)).destroy_all
      SolidQueue::Semaphore.where("key LIKE ?", "%#{described_class.name}%").delete_all
    end
  end
end
