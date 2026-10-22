# Refunds are payments too: money paid back to a customer (refund) or back from a supplier
# (supplier_refund), each using up a credit (an overpayment or a credit note).
class AddRefundKindsToTudlaAccountingPayments < ActiveRecord::Migration[8.1]
  def change
    remove_check_constraint :tudla_accounting_payments, "kind IN ('received', 'paid')", name: "tudla_accounting_payments_kind_known"
    add_check_constraint :tudla_accounting_payments, "kind IN ('received', 'paid', 'refund', 'supplier_refund')", name: "tudla_accounting_payments_kind_known"
  end
end
