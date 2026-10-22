# The dimension values (department, project...) an invoice or bill line is tagged with,
# one per dimension, as a recurring entry's line has them; approving the document tags the
# line's posting with them.
class AddDimensionValueIdsToTudlaAccountingDocumentLines < ActiveRecord::Migration[8.1]
  def change
    add_column :tudla_accounting_document_lines, :dimension_value_ids, :bigint, array: true, null: false, default: []
  end
end
