require "rails_helper"

RSpec.describe TudlaAccounting::ApiToken do
  include ActiveSupport::Testing::TimeHelpers

  let(:organization) { create(:organization) }

  it "issues a token whose secret is kept only as a digest, and finds it by the secret" do
    token, secret = TudlaAccounting::Current.set(actor: "Sam") { described_class.issue!(organization: organization, name: "  Shop   sync ", permissions: %w[post read nonsense]) }
    expect(secret).to match(/\Atudla_[1-9A-HJ-NP-Za-km-z]{40}\z/)
    expect(token).to have_attributes(name: "Shop sync", permissions: %w[read post], hint: secret.first(10), masked: "#{secret.first(10)}…", created_by: "Sam", active?: true)
    expect(token.token_digest).to eq(OpenSSL::Digest::SHA256.hexdigest(secret))
    expect(described_class.where(token_digest: secret)).to be_empty
    expect(token.can?(:read)).to be(true)
    expect(token.can?("administer")).to be(false)

    expect(described_class.authenticate(secret)).to eq(token)
    expect(token.reload.last_used_at).to be_within(1.second).of(Time.current)
    [ nil, "", "tudla_wrong", "bearer #{secret}", secret + "x", "tudla_#{'a' * 300}" ].each { |guess| expect(described_class.authenticate(guess)).to be_nil }

    event = TudlaAccounting::AuditEvent.find_by!(action: "api_token.created")
    expect(event).to have_attributes(subject: token, subject_label: "API token Shop sync", actor_label: "Sam", details: { "permissions" => %w[read post] })
  end

  it "notes its last use at most once a minute" do
    token, secret = described_class.issue!(organization: organization, name: "Shop", permissions: %w[read])
    travel_to(Time.zone.local(2026, 4, 1, 9)) { described_class.authenticate(secret) }
    travel_to(Time.zone.local(2026, 4, 1, 9, 0, 30)) { described_class.authenticate(secret) }
    expect(token.reload.last_used_at).to eq(Time.zone.local(2026, 4, 1, 9))
    travel_to(Time.zone.local(2026, 4, 1, 9, 2)) { described_class.authenticate(secret) }
    expect(token.reload.last_used_at).to eq(Time.zone.local(2026, 4, 1, 9, 2))
  end

  it "stops working once revoked or past its expiry, acting as itself on the audit trail" do
    token, secret = described_class.issue!(organization: organization, name: "Shop", permissions: %w[read], expires_on: Date.new(2026, 4, 30))
    travel_to(Time.zone.local(2026, 4, 30, 23)) { expect(described_class.authenticate(secret)).to eq(token) }
    travel_to(Time.zone.local(2026, 5, 1, 1)) do
      expect(described_class.authenticate(secret)).to be_nil
      expect(token).to be_expired
    end

    other, other_secret = described_class.issue!(organization: organization, name: "Payroll", permissions: %w[read record])
    TudlaAccounting::Current.set(actor: other) { other.revoke! }
    expect(described_class.authenticate(other_secret)).to be_nil
    expect(other.reload).to have_attributes(revoked?: true, active?: false, revoked_by: "API token Payroll")
    expect { other.revoke! }.to raise_error(ArgumentError, "This token is revoked already")
    event = TudlaAccounting::AuditEvent.find_by!(action: "api_token.revoked")
    expect(event).to have_attributes(actor: other, actor_label: "API token Payroll")
  end

  it "needs a name and a permission, and can't be changed or deleted" do
    expect { described_class.issue!(organization: organization, name: "", permissions: []) }.to raise_error(ActiveRecord::RecordInvalid, /Name can't be blank, Permissions choose at least one/)
    token, = described_class.issue!(organization: organization, name: "Shop", permissions: %w[read])
    expect(token.update(permissions: %w[administer])).to be(false)
    expect(token.errors[:base]).to eq([ "A token can't be changed; revoke it and issue another" ])
    expect(token.reload.destroy).to be(false)
  end
end
