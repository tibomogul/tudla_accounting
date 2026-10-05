require "rails_helper"

# Real concurrency against the database: these examples commit their data so that
# separate threads (and connections) can see it, then clean up after themselves.
RSpec.describe "Concurrent posting" do
  self.use_transactional_tests = false

  let(:organizations) { [] }

  after do
    # Posted entries are protected in the database; purging test books is the
    # legitimate exception.
    TudlaAccounting::DatabaseProtection.allowing_posted_changes { purge_books }
  end

  def purge_books
    org_ids = organizations.map(&:id)
    scope = ->(model) { model.where(organization_type: "Organization", organization_id: org_ids) }
    entry_ids = scope.call(TudlaAccounting::Entry).pluck(:id)
    detail_ids = TudlaAccounting::Detail.where(entry_id: entry_ids).pluck(:id)

    TudlaAccounting::CarryingAmount.where(detail_id: detail_ids).delete_all
    TudlaAccounting::ForeignExchange.where(detail_id: detail_ids).delete_all
    TudlaAccounting::Detail.where(id: detail_ids).delete_all
    scope.call(TudlaAccounting::Balance).delete_all
    TudlaAccounting::Entry.where(id: entry_ids).delete_all
    scope.call(TudlaAccounting::Account).delete_all
    scope.call(TudlaAccounting::Period).delete_all
    Organization.where(id: org_ids).delete_all
  end

  def books
    org = Organization.create!(name: "Concurrent #{SecureRandom.hex(4)}", currency: "USD")
    organizations << org
    TudlaAccounting::PeriodCreator.call(org, 2026)
    cash = TudlaAccounting::Account.create!(organization: org, code: "1000", name: "Cash", category: :asset, currency: "USD")
    capital = TudlaAccounting::Account.create!(organization: org, code: "3000", name: "Capital", category: :equity, currency: "USD")
    [ org, cash, capital ]
  end

  def entry_for(org, cash, capital, cents = 100)
    entry = TudlaAccounting::Entry.new(organization: org, particulars: "Contribution", transacted_at: Time.zone.local(2026, 3, 10))
    entry.details.build(account: cash, tally: :debit, amount_cents: cents, currency: "USD", organization: org)
    entry.details.build(account: capital, tally: :credit, amount_cents: cents, currency: "USD", organization: org)
    entry.tap(&:save!)
  end

  def in_threads(items)
    items.map do |item|
      Thread.new { ActiveRecord::Base.connection_pool.with_connection { yield item } }
    end.map { |thread| thread.join(30) ? thread.value : raise("thread did not finish") }
  end

  it "keeps every amount when many entries for one organization post at once" do
    org, cash, capital = books
    entries = Array.new(12) { |i| entry_for(org, cash, capital, (i + 1) * 100) }
    gate = Queue.new

    workers = Array.new(4) do |worker|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.pop
          entries.each_slice(4).map { |slice| slice[worker] }.compact.each { |entry| entry.post(entry.transacted_at) }
        end
      end
    end
    4.times { gate << :go }
    workers.each { |worker| expect(worker.join(30)).to be_truthy }

    total = entries.sum { |entry| entry.details.first.amount_cents }
    year = TudlaAccounting::Period.roots.find_by(organization: org)
    [ cash, capital ].each do |account|
      expect(TudlaAccounting::Balance.find_by(account: account, period: year).current_amount_cents).to eq(total)
    end
  end

  it "posts an entry only once when two posts of it race" do
    org, cash, capital = books
    entry = entry_for(org, cash, capital)

    results = in_threads([ entry.id, entry.id ]) do |id|
      TudlaAccounting::Entry.find(id).post(Time.zone.local(2026, 3, 10))
      :posted
    rescue ArgumentError => e
      e.message
    end

    expect(results).to contain_exactly(:posted, "entry is already posted")
    year = TudlaAccounting::Period.roots.find_by(organization: org)
    expect(TudlaAccounting::Balance.find_by(account: cash, period: year).current_amount_cents).to eq(100)
  end

  it "makes posts for the same organization wait, but not posts for other organizations" do
    org, cash, capital = books
    other_org, other_cash, other_capital = books
    same_org_entry = entry_for(org, cash, capital)
    other_org_entry = entry_for(other_org, other_cash, other_capital)
    locked = Queue.new
    release = Queue.new

    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          Organization.lock.find(org.id)
          locked << true
          release.pop
        end
      end
    end
    locked.pop

    begin
      same_org = Thread.new { ActiveRecord::Base.connection_pool.with_connection { same_org_entry.post(same_org_entry.transacted_at) } }
      other = Thread.new { ActiveRecord::Base.connection_pool.with_connection { other_org_entry.post(other_org_entry.transacted_at) } }

      expect(other.join(5)).to be_truthy    # other organization is not blocked
      expect(same_org.join(0.5)).to be_nil  # same organization waits for the lock
    ensure
      release << true # never leave the lock held, or cleanup would wait on it forever
      holder.join(5)
    end
    expect(same_org.join(5)).to be_truthy

    expect(same_org_entry.reload.posted_at).to be_present
    expect(other_org_entry.reload.posted_at).to be_present
  end

  it "locks when a detail is posted on its own" do
    org, cash, capital = books
    detail = entry_for(org, cash, capital).details.first

    expect(Organization).to receive(:lock).and_call_original
    detail.post(Time.zone.local(2026, 3, 10))
  end
end
