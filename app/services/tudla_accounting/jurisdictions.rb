# frozen_string_literal: true

module TudlaAccounting
  # What belongs to one country: the reports and fields an organization has only when the
  # country setting gives it that country (or gives it none, for every country's). Every
  # country check outside the templates reads this list, so it is the place to start when
  # adding a country or moving one into an add-on. The templates (TaxReturnTemplates,
  # WithholdingCodeTemplates) say their own country, and choices offers only the books'.
  #
  #   Jurisdictions.on?(organization, :taxable_payments)
  module Jurisdictions
    FEATURES = {
      # The Philippines (the BIR)
      books_of_accounts: "PH",   # the books report and its sample
      summary_lists: "PH",       # the SLSP reports, and TaxCode#purchase_type's field
      withholding_reports: "PH", # the withholding summary, QAP, SAWT and 2307s
      customer_certificates: "PH", # marking customers' 2307s received, and the list to chase (the SAWT lists what's marked)
      # Australia (the ATO)
      payee_payments: "AU",      # the payee list and its payment summaries
      taxable_payments: "AU"     # the TPAR, and Contact#taxable_payments's field
    }.freeze

    module_function

    # The country a feature belongs to.
    def country(feature) = FEATURES.fetch(feature)

    # Whether an organization has a feature: it's that country's, or has no country.
    def on?(organization, feature) = TudlaAccounting.configuration.country?(organization, country(feature))

    # The templates (a hash of key => { country:, ... }) an organization's country offers.
    def templates_for(organization, templates)
      templates.select { |_, template| TudlaAccounting.configuration.country?(organization, template.fetch(:country)) }
    end
  end
end
