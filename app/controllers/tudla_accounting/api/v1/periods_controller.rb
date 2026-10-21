module TudlaAccounting
  module Api
    module V1
      # Financial years and their months, latest first, with whether each is closed; their
      # ids pick the periods reports cover.
      class PeriodsController < BaseController
        include Representation

        def index
          render_page(organization_scope(Period).order(from_date: :desc, ancestry: :asc)) { |period| period_json(period) }
        end
      end
    end
  end
end
