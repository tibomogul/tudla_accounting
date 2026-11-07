require "rails_helper"

RSpec.describe TudlaAccounting::Engine do
  # A host app's FactoryBot loads only its own factories: the engine's (spec/factories,
  # which may share names with the host's, such as :organization) come from the dummy app.
  it "leaves a host app's FactoryBot paths alone" do
    expect(Dir[described_class.root.join("lib/**/*.rb")].select { |file| File.read(file).include?("FactoryBot") }).to be_empty
    expect(FactoryBot.definition_file_paths.map(&:to_s)).to include(described_class.root.join("spec/factories").to_s)
  end
end
