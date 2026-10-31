require "rails_helper"

RSpec.describe TudlaAccounting::BspRatesJob, type: :job do
  it "stores the day's BSP bulletin, once" do
    provider = TudlaAccounting::BspForexRateProvider.new(open: ->(_url) { file_fixture("bsp_rerb.xlsx").open })
    allow(TudlaAccounting::BspForexRateProvider).to receive(:new).and_return(provider)
    allow(Rails.logger).to receive(:info)

    described_class.perform_now
    described_class.perform_now

    expect(TudlaAccounting::ForexRate.where(to: "PHP", year: 2026, month: 10, day: 30).count).to eq(31)
    expect(Rails.logger).to have_received(:info).with("TudlaAccounting: stored 31 BSP rates").ordered
    expect(Rails.logger).to have_received(:info).with("TudlaAccounting: stored 0 BSP rates").ordered
  end
end
