require "rails_helper"

# Every organization's books are kept apart by convention: a page or API request looks up
# records only through organization_scope (the current organization's). This fails for a
# query on an engine model, in the engine's controllers, views and helpers, that isn't
# limited by organization_scope on the same line. One that is safe another way (it starts
# from records already scoped, or the model has no organization of its own) says why in a
# "tenancy:" comment on that line or the one before.
module TenancyCheck
  module_function

  def files = %w[app/controllers app/views app/helpers].flat_map { |dir| Dir[TudlaAccounting::Engine.root.join(dir, "**/*.{rb,erb}")] }

  def models
    Rails.application.eager_load!
    ActiveRecord::Base.descendants.select { |model| model.name&.start_with?("TudlaAccounting::") && !model.abstract_class? }
  end

  # The class methods that query: ActiveRecord's own, and each model's named scopes
  # (enums' included). none and the builders don't read anything.
  def queries(model)
    scopes = model.singleton_methods(false).select { |name| model.method(name).source_location&.first.to_s.include?("active_record/scoping/named") }
    (ActiveRecord::Querying::QUERYING_METHODS + scopes + %i[all unscoped]).map(&:to_s) - %w[none new build create create! find_or_initialize_by]
  end

  def pattern
    @pattern ||= begin
      alternatives = models.sort_by { |model| -model.name.length }.map do |model|
        "(?:TudlaAccounting::)?#{Regexp.escape(model.name.delete_prefix('TudlaAccounting::'))}\\.(?:#{queries(model).map { |name| Regexp.escape(name) }.join('|')})(?![\\w!?])"
      end
      Regexp.new("(?<![\\w:])(?:#{alternatives.join('|')})")
    end
  end

  # The numbers of the lines with an unscoped lookup.
  def unscoped_lookups(lines)
    lines.each_with_index.filter_map do |line, index|
      next unless line.match?(pattern)
      next if line.include?("organization_scope(") || line.include?("tenancy:") || (index.positive? && lines[index - 1].include?("tenancy:"))

      index + 1
    end
  end
end

RSpec.describe "Tenancy" do
  it "looks up records only through organization_scope" do
    found = TenancyCheck.files.flat_map do |file|
      TenancyCheck.unscoped_lookups(File.readlines(file)).map { |number| "#{Pathname(file).relative_path_from(TudlaAccounting::Engine.root)}:#{number}" }
    end
    expect(found).to be_empty, "Unscoped lookups (use organization_scope, or say why it's safe in a tenancy: comment):\n#{found.join("\n")}"
  end

  it "catches a lookup that isn't scoped, scopes and all" do
    expect(TenancyCheck.unscoped_lookups([ "Entry.find(params[:id])", "TudlaAccounting::Payment.received.to_a", "Delivery.sent.count", "organization_scope(Entry).find(1)",
                                           "# tenancy: the scoped document's lines", "DimensionValue.where(id: ids)", "WithholdingCode.none", "Entry::KINDS", "entries.where(id: 1)" ]))
      .to eq([ 1, 2, 3 ])
  end
end
