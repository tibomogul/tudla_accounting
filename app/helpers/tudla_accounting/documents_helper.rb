module TudlaAccounting
  module DocumentsHelper
    # How a document stands: Draft, Void, or how far it is paid (a credit note, applied),
    # Overdue once past its due date with something still owed.
    def document_status_badge(document, today: ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone].today)
      status = document.payment_status
      return tc_badge("Draft", tone: :warning) if status == "draft"
      return tc_badge("Void", tone: :danger) if status == "void"
      return tc_badge(document.credit? ? "Applied" : "Paid", tone: :success) if status == "paid"
      return tc_badge("Overdue", tone: :danger) if document.due_on && document.due_on < today

      if status == "part_paid"
        tc_badge(document.credit? ? "Part applied" : "Part paid", tone: :primary)
      else
        tc_badge(document.credit? ? "Not applied" : "Awaiting payment", tone: :primary)
      end
    end

    # "1" for 1.0000, "2.5" for 2.5000.
    def document_quantity(quantity)
      quantity.to_d.to_s("F").sub(/\.?0+\z/, "")
    end

    # A typed amount for the line editor: "1234.50", or "" for nothing yet.
    def document_price(line)
      line.unit_price_cents.to_i.positive? ? line.unit_price.format(symbol: false, thousands_separator: "") : ""
    end
  end
end
