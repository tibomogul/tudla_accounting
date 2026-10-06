module TudlaAccounting
  # The values of a dimension (e.g. the departments).
  class DimensionValuesController < ApplicationController
    permits :administer, only: %i[new create edit update]

    before_action :set_dimension
    before_action :set_value, only: %i[edit update]

    def new
      @value = @dimension.dimension_values.new
    end

    def create
      @value = @dimension.dimension_values.new(value_params)
      if @value.save
        redirect_to dimensions_path, notice: "#{@value.label} was added."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @value.update(value_params)
        redirect_to dimensions_path, notice: "#{@value.label} was saved."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def set_dimension
      @dimension = organization_scope(Dimension).find(params[:dimension_id])
    end

    def set_value
      @value = @dimension.dimension_values.find(params[:id])
    end

    def value_params
      params.require(:dimension_value).permit(:code, :name, :active)
    end
  end
end
