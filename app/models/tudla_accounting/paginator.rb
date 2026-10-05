# frozen_string_literal: true

module TudlaAccounting
  # Splits a scope into pages for the engine's lists:
  #
  #   @page = Paginator.new(organization_scope(Entry).order(:id), page: params[:page])
  #   @page.records # this page's records
  class Paginator
    PER_PAGE = 25

    attr_reader :page, :per_page, :total_count

    def initialize(scope, page:, per_page: PER_PAGE)
      @scope = scope
      @per_page = per_page
      @total_count = scope.count
      @page = page.to_i.clamp(1, total_pages)
    end

    def records
      @scope.limit(per_page).offset((page - 1) * per_page)
    end

    def total_pages
      [ (total_count / per_page.to_f).ceil, 1 ].max
    end

    def previous_page
      page - 1 if page > 1
    end

    def next_page
      page + 1 if page < total_pages
    end

    # Page numbers to show, with nil for a gap: [1, nil, 4, 5, 6, nil, 10]
    def window(around: 1)
      pages = ([ 1, total_pages ] + ((page - around)..(page + around)).to_a).select { |number| number.between?(1, total_pages) }.uniq.sort
      pages.each_with_index.flat_map { |number, index| index.positive? && number - pages[index - 1] > 1 ? [ nil, number ] : [ number ] }
    end
  end
end
