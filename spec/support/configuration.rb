# Lets an example change TudlaAccounting.configuration without leaking into other examples.
RSpec.shared_context "with isolated TudlaAccounting configuration" do
  around do |example|
    original = TudlaAccounting.configuration
    TudlaAccounting.configuration = original.dup
    example.run
  ensure
    TudlaAccounting.configuration = original
  end
end
