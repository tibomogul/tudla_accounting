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
      },
      # BIR Form No. 2550Q, April 2024 (ENCS): Part IV's computation (column A, the sales
      # or purchases; column B, their tax), then Part II's total payable, which starts
      # from it. Its schedules (Part V) are worked out off the books.
      "ph_2550q" => {
        title: "Philippines: Quarterly VAT return (BIR Form 2550Q, April 2024)",
        name: "2550Q",
        boxes: [
          { label: "31A", name: "VATable sales (exclusive of VAT)" },
          { label: "31B", name: "Output tax on VATable sales" },
          { label: "32A", name: "Zero-rated sales" },
          { label: "33A", name: "Exempt sales" },
          { label: "34A", name: "Total sales (sum of items 31A to 33A)", boxes: { "31A" => 1, "32A" => 1, "33A" => 1 } },
          { label: "34B", name: "Total output tax due (item 31B)", boxes: { "31B" => 1 } },
          { label: "35B", name: "Less: output VAT on uncollected receivables" },
          { label: "36B", name: "Add: output VAT on recovered uncollected receivables previously deducted" },
          { label: "37B", name: "Total adjusted output tax due (item 34B less item 35B add item 36B)", boxes: { "34B" => 1, "35B" => -1, "36B" => 1 } },
          { label: "38B", name: "Input tax carried over from previous quarter" },
          { label: "39B", name: "Input tax deferred on capital goods exceeding ₱1 million from previous quarter" },
          { label: "40B", name: "Transitional input tax" },
          { label: "41B", name: "Presumptive input tax" },
          { label: "42B", name: "Other allowable input tax" },
          { label: "43B", name: "Total (sum of items 38B to 42B)", boxes: { "38B" => 1, "39B" => 1, "40B" => 1, "41B" => 1, "42B" => 1 } },
          { label: "44A", name: "Domestic purchases" },
          { label: "44B", name: "Input tax on domestic purchases" },
          { label: "45A", name: "Services rendered by non-residents" },
          { label: "45B", name: "Input tax on services rendered by non-residents" },
          { label: "46A", name: "Importations" },
          { label: "46B", name: "Input tax on importations" },
          { label: "47A", name: "Other purchases" },
          { label: "47B", name: "Input tax on other purchases" },
          { label: "48A", name: "Domestic purchases with no input tax" },
          { label: "49A", name: "VAT-exempt importations" },
          { label: "50A", name: "Total current purchases (sum of items 44A to 49A)", boxes: { "44A" => 1, "45A" => 1, "46A" => 1, "47A" => 1, "48A" => 1, "49A" => 1 } },
          { label: "50B", name: "Total current input tax (sum of items 44B to 47B)", boxes: { "44B" => 1, "45B" => 1, "46B" => 1, "47B" => 1 } },
          { label: "51B", name: "Total available input tax (sum of items 43B and 50B)", boxes: { "43B" => 1, "50B" => 1 } },
          { label: "52B", name: "Input tax on purchases/importation of capital goods exceeding ₱1 million deferred for the succeeding period" },
          { label: "53B", name: "Input tax attributable to VAT exempt sales" },
          { label: "54B", name: "VAT refund/TCC claimed" },
          { label: "55B", name: "Input VAT on unpaid payables" },
          { label: "56B", name: "Other deductions from input tax" },
          { label: "57B", name: "Total deductions from input tax (sum of items 52B to 56B)", boxes: { "52B" => 1, "53B" => 1, "54B" => 1, "55B" => 1, "56B" => 1 } },
          { label: "58B", name: "Add: input VAT on settled unpaid payables previously deducted" },
          { label: "59B", name: "Adjusted deductions from input tax (sum of items 57B and 58B)", boxes: { "57B" => 1, "58B" => 1 } },
          { label: "60B", name: "Total allowable input tax (item 51B less item 59B)", boxes: { "51B" => 1, "59B" => -1 } },
          { label: "61B", name: "Net VAT payable/(excess input tax) (item 37B less item 60B)", boxes: { "37B" => 1, "60B" => -1 } },
          { label: "15", name: "Net VAT payable/(excess input tax) (from Part IV, item 61)", boxes: { "61B" => 1 } },
          { label: "16", name: "Creditable VAT withheld" },
          { label: "17", name: "Advance VAT payments" },
          { label: "18", name: "VAT paid in return previously filed, if this is an amended return" },
          { label: "19", name: "Other credits/payment" },
          { label: "20", name: "Total tax credits/payment (sum of items 16 to 19)", boxes: { "16" => 1, "17" => 1, "18" => 1, "19" => 1 } },
          { label: "21", name: "Tax still payable/(excess credits) (item 15 less item 20)", boxes: { "15" => 1, "20" => -1 } },
          { label: "22", name: "Surcharge" },
          { label: "23", name: "Interest" },
          { label: "24", name: "Compromise" },
          { label: "25", name: "Total penalties (sum of items 22 to 24)", boxes: { "22" => 1, "23" => 1, "24" => 1 } },
          { label: "26", name: "Total amount payable/(excess credits) (sum of items 21 and 25)", boxes: { "21" => 1, "25" => 1 } }
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
