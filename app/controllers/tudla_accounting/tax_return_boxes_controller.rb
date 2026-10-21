module TudlaAccounting
  # The boxes of a tax return form, each with the parts it adds up. See TaxReturnBox.
  class TaxReturnBoxesController < ApplicationController
    BLANK_PARTS = 3 # empty rows for new parts

    permits :administer, only: %i[new create edit update destroy]

    before_action :set_form
    before_action :set_box, only: %i[edit update destroy]
    helper_method :part_choices

    def new
      @box = @form.boxes.new(position: (@form.boxes.maximum(:position) || 0) + 10)
      BLANK_PARTS.times { @box.parts.build(sign: 1) }
    end

    def create
      @box = @form.boxes.new(box_params)
      save(:new)
    end

    def edit
      BLANK_PARTS.times { @box.parts.build(sign: 1) }
    end

    def update
      @box.assign_attributes(box_params)
      save(:edit)
    end

    def destroy
      if @box.destroy
        redirect_to tax_return_form_path(@form), notice: "Box #{@box.label} deleted."
      else
        redirect_to tax_return_form_path(@form), alert: @box.errors.full_messages.to_sentence
      end
    end

    private

    def set_form
      @form = organization_scope(TaxReturnForm).find(params[:tax_return_form_id])
    end

    def set_box
      @box = @form.boxes.find(params[:id])
    end

    def save(view)
      if @box.save
        redirect_to tax_return_form_path(@form), notice: "Box #{@box.label} saved."
      else
        (BLANK_PARTS - @box.parts.count(&:new_record?)).times { @box.parts.build(sign: 1) }
        render view, status: :unprocessable_entity
      end
    end

    # The box's fields and its parts (the organization's tax codes, accounts and this
    # form's boxes, checked by the box).
    def box_params
      params.require(:tax_return_box).permit(:label, :name, :position, :whole_units,
                                             parts_attributes: %i[id source sign tax_code_id account_id from_box_id _destroy])
    end

    # The choices for a part: { tax_codes:, accounts:, boxes: } (boxes above this one).
    def part_choices
      @part_choices ||= {
        tax_codes: organization_scope(TaxCode).order(:kind, :code).map { |code| [ "#{code.code} – #{code.name} (#{code.kind})", code.id ] },
        accounts: organization_scope(Account).order(:code).map { |account| [ helpers.account_option_label(account), account.id ] },
        boxes: @form.boxes.where.not(id: @box.id).map { |box| [ box.title, box.id ] }
      }
    end
  end
end
