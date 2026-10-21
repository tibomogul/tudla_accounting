# frozen_string_literal: true

module TudlaAccounting
  # Ready-made tax return layouts: each box's label, name, whether it is in whole units,
  # and the boxes it totals ({ label => 1 or -1 }). Which tax codes and accounts fill the
  # other boxes depends on each organization's own, so TaxReturnForm.from_template! leaves
  # those to be added. The names follow the published forms; check them against the
  # current form before filing.
  module TaxReturnTemplates
    TEMPLATES = {
      "au_bas" => {
        title: "Australia: Business activity statement (GST and PAYG withholding)",
        name: "BAS",
        boxes: [
          { label: "G1", name: "Total sales (including any GST)", whole_units: true },
          { label: "G2", name: "Export sales", whole_units: true },
          { label: "G3", name: "Other GST-free sales", whole_units: true },
          { label: "G10", name: "Capital purchases (including any GST)", whole_units: true },
          { label: "G11", name: "Non-capital purchases (including any GST)", whole_units: true },
          { label: "1A", name: "GST on sales", whole_units: true },
          { label: "1B", name: "GST on purchases", whole_units: true },
          { label: "W1", name: "Total salary, wages and other payments", whole_units: true },
          { label: "W2", name: "Amount withheld from payments shown at W1", whole_units: true },
          { label: "Net GST", name: "GST payable (1A less 1B; negative is a refund)", whole_units: true, boxes: { "1A" => 1, "1B" => -1 } }
        ]
      },
      "uk_vat" => {
        title: "United Kingdom: VAT return (boxes 1 to 9)",
        name: "VAT return",
        boxes: [
          { label: "Box 1", name: "VAT due on sales and other outputs" },
          { label: "Box 2", name: "VAT due on acquisitions of goods made in Northern Ireland from EU member states" },
          { label: "Box 3", name: "Total VAT due (box 1 + box 2)", boxes: { "Box 1" => 1, "Box 2" => 1 } },
          { label: "Box 4", name: "VAT reclaimed on purchases and other inputs (including acquisitions in Northern Ireland from EU member states)" },
          { label: "Box 5", name: "Net VAT to pay to HMRC or reclaim (box 3 less box 4)", boxes: { "Box 3" => 1, "Box 4" => -1 } },
          { label: "Box 6", name: "Total value of sales and all other outputs excluding any VAT", whole_units: true },
          { label: "Box 7", name: "Total value of purchases and all other inputs excluding any VAT", whole_units: true },
          { label: "Box 8", name: "Total value of dispatches of goods and related costs (excluding VAT) from Northern Ireland to EU member states", whole_units: true },
          { label: "Box 9", name: "Total value of acquisitions of goods and related costs (excluding VAT) made in Northern Ireland from EU member states", whole_units: true }
        ]
      }
    }.freeze

    module_function

    def fetch(key)
      TEMPLATES.fetch(key.to_s) { raise ArgumentError, "Unknown tax return template #{key.inspect}; expected one of #{TEMPLATES.keys.join(', ')}" }
    end

    # [[title, key]] for a select.
    def choices
      TEMPLATES.map { |key, template| [ template[:title], key ] }
    end
  end
end
