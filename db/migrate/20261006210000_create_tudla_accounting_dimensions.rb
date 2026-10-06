# Reporting dimensions (department, project, location...): each has values, and entry
# lines are tagged with at most one value per dimension.
class CreateTudlaAccountingDimensions < ActiveRecord::Migration[8.1]
  def change
    create_table :tudla_accounting_dimensions do |t|
      t.references :organization, polymorphic: true, null: false, index: false
      t.string :code, null: false
      t.string :name, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :tudla_accounting_dimensions, %i[organization_type organization_id code], unique: true, name: "tudla_accounting_dimensions_unique_key"

    create_table :tudla_accounting_dimension_values do |t|
      t.references :dimension, null: false, foreign_key: { to_table: :tudla_accounting_dimensions }, index: false
      t.string :code, null: false
      t.string :name, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :tudla_accounting_dimension_values, %i[dimension_id code], unique: true, name: "tudla_accounting_dimension_values_unique_key"

    create_table :tudla_accounting_detail_tags do |t|
      t.references :detail, null: false, foreign_key: { to_table: :tudla_accounting_details }, index: false
      t.references :dimension, null: false, foreign_key: { to_table: :tudla_accounting_dimensions }
      t.references :dimension_value, null: false, foreign_key: { to_table: :tudla_accounting_dimension_values }
      t.timestamps
    end
    add_index :tudla_accounting_detail_tags, %i[detail_id dimension_id], unique: true, name: "tudla_accounting_detail_tags_unique_key"
  end
end
