module TudlaAccounting
  # Tax return forms and their boxes, set up alongside the tax codes. See TaxReturnForm.
  class TaxReturnFormsController < ApplicationController
    permits :administer, only: %i[index new create show edit update destroy]

    before_action :set_form, only: %i[show edit update destroy]

    def index
      @forms = organization_scope(TaxReturnForm).includes(:boxes).order(:name).to_a
    end

    def new
      @form = organization_scope(TaxReturnForm).new
    end

    # A blank form, or one laid out as a template says.
    def create
      @template = params[:template].presence_in(TaxReturnTemplates::TEMPLATES.keys)
      name = params.require(:tax_return_form)[:name]
      @form = @template ? TaxReturnForm.from_template!(accounting_organization, @template, name: name) : organization_scope(TaxReturnForm).create!(name: name)
      redirect_to tax_return_form_path(@form), notice: "Tax return #{@form.name} added.#{' Add the tax codes and accounts that fill its boxes.' if @template}"
    rescue ActiveRecord::RecordInvalid => e
      @form = e.record.is_a?(TaxReturnForm) ? e.record : organization_scope(TaxReturnForm).new(name: name)
      render :new, status: :unprocessable_entity
    end

    def show
      @boxes = @form.boxes.includes(parts: %i[tax_code account from_box]).to_a
    end

    def edit
    end

    def update
      if @form.update(params.require(:tax_return_form).permit(:name))
        redirect_to tax_return_form_path(@form), notice: "Tax return #{@form.name} saved."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      if @form.destroy
        redirect_to tax_return_forms_path, notice: "Tax return #{@form.name} deleted."
      else
        redirect_to tax_return_form_path(@form), alert: @form.errors.full_messages.to_sentence
      end
    end

    private

    def set_form
      @form = organization_scope(TaxReturnForm).find(params[:id])
    end
  end
end
