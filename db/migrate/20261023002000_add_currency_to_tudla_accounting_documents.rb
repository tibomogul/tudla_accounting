# An invoice, bill or credit note in a foreign currency: its amounts are in currency, and
# exchange_rate (how many of the organization's currency one unit of it was worth) turns
# them into the organization's for posting. Both nil for one in the organization's own.
class AddCurrencyToTudlaAccountingDocuments < ActiveRecord::Migration[8.1]
  def change
    add_column :tudla_accounting_documents, :currency, :string, limit: 3
    add_column :tudla_accounting_documents, :exchange_rate, :decimal, precision: 24, scale: 8
    add_check_constraint :tudla_accounting_documents, "(currency IS NULL) = (exchange_rate IS NULL) AND (exchange_rate IS NULL OR exchange_rate > 0)",
                         name: "tudla_accounting_documents_foreign_currency_rated"
  end
end
