require_relative "configuration"

# Temporary host-app models (Invoice, Bill, Payment, Disbursement, CreditNote,
# SupplierCredit, Refund, SupplierRefund) that act as polymorphic entry sources, configured as the carrying amount
# roles with accounts receivable at code 1100 and accounts payable at 2100. Each can name
# a customer (an Organization standing in for the customer or supplier).
RSpec.shared_context "with entry source models" do
  include_context "with isolated TudlaAccounting configuration"

  sources = { "Invoice" => :receivable, "Bill" => :payable, "Payment" => :receipt, "Disbursement" => :disbursement,
              "CreditNote" => :credit_note, "SupplierCredit" => :supplier_credit, "Refund" => :refund, "SupplierRefund" => :supplier_refund }

  before do
    TudlaAccounting.configure do |config|
      config.receivable_account_code = "1100"
      config.payable_account_code = "2100"
      config.carrying_amount_sources = sources
    end
  end

  before(:all) do
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      sources.each_key do |name|
        create_table name.tableize, force: true do |t|
          t.datetime :due_date
          t.bigint :customer_id
          t.timestamps
        end
      end
    end

    sources.each_key do |name|
      model = Object.const_set(name, Class.new(ApplicationRecord) { self.table_name = name.tableize })
      model.belongs_to :customer, class_name: "Organization", optional: true
    end
  end

  after(:all) do
    ActiveRecord::Schema.define do
      sources.each_key { |name| drop_table name.tableize, if_exists: true }
    end

    sources.each_key { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end
end
