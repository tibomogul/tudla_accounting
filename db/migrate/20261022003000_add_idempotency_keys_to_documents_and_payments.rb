# A key another system sends with a request to create one (the API's Idempotency-Key), so
# a retried request returns what the first made instead of making it twice.
class AddIdempotencyKeysToDocumentsAndPayments < ActiveRecord::Migration[8.1]
  def change
    %i[documents payments].each do |table|
      add_column :"tudla_accounting_#{table}", :idempotency_key, :string
      add_index :"tudla_accounting_#{table}", %i[organization_type organization_id idempotency_key], unique: true, where: "idempotency_key IS NOT NULL",
                                                                                                    name: "tudla_accounting_#{table}_idempotency_key"
    end
  end
end
