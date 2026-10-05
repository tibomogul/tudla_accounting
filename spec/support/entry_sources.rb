require_relative "configuration"

# Temporary host-app models (Invoice, Bill, Payment, Disbursement) that act as
# polymorphic entry sources, configured as the four carrying amount roles with
# accounts receivable at code 1100 and accounts payable at 2100.
RSpec.shared_context "with entry source models" do
  include_context "with isolated TudlaAccounting configuration"

  before do
    TudlaAccounting.configure do |config|
      config.receivable_account_code = "1100"
      config.payable_account_code = "2100"
      config.carrying_amount_sources = {
        "Invoice" => :receivable, "Bill" => :payable, "Payment" => :receipt, "Disbursement" => :disbursement
      }
    end
  end

  before(:all) do
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table :invoices, force: true do |t|
        t.datetime :due_date
        t.timestamps
      end

      create_table :bills, force: true do |t|
        t.datetime :due_date
        t.timestamps
      end

      create_table :payments, force: true, &:timestamps
      create_table :disbursements, force: true, &:timestamps
    end

    %w[Invoice Bill Payment Disbursement].each do |name|
      Object.const_set(name, Class.new(ApplicationRecord) { self.table_name = name.tableize })
    end
  end

  after(:all) do
    ActiveRecord::Schema.define do
      %i[invoices bills payments disbursements].each { |table| drop_table table, if_exists: true }
    end

    %w[Invoice Bill Payment Disbursement].each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name)
    end
  end
end
