module TudlaAccounting
  # The organization's reporting dimensions (department, project...) and their values.
  class DimensionsController < ApplicationController
    permits :administer, only: %i[index new create edit update]

    before_action :set_dimension, only: %i[edit update]

    def index
      @dimensions = organization_scope(Dimension).includes(:dimension_values).order(:code)
    end

    def new
      @dimension = organization_scope(Dimension).new
    end

    def create
      @dimension = organization_scope(Dimension).new(dimension_params)
      if @dimension.save
        redirect_to dimensions_path, notice: "Dimension #{@dimension.label} was added. Add its values next."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @dimension.update(dimension_params)
        redirect_to dimensions_path, notice: "Dimension #{@dimension.label} was saved."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def set_dimension
      @dimension = organization_scope(Dimension).find(params[:id])
    end

    def dimension_params
      params.require(:dimension).permit(:code, :name, :active)
    end
  end
end
