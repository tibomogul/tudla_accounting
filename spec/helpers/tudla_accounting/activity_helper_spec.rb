require "rails_helper"

RSpec.describe TudlaAccounting::ActivityHelper, type: :helper do
  describe "#rebuilt_description" do
    it "names the accounts a rebuild corrected" do
      expect(helper.rebuilt_description("corrected" => 2, "accounts" => %w[3000 3900]))
        .to eq("Rebuilt the balances: 2 balances corrected (3000 and 3900)")
    end

    # Recorded before the accounts were.
    it "gives the count alone for older events" do
      expect(helper.rebuilt_description("corrected" => 3)).to eq("Rebuilt the balances: 3 balances corrected")
    end
  end
end
