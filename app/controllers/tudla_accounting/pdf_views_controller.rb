module TudlaAccounting
  # Renders the pages PDFs are made from, outside any request (from a job, say): no
  # routes, no host controller, no sign-in. Its views get what they show through locals.
  # See PdfMaker.
  class PdfViewsController < ActionController::Base
    layout "tudla_accounting/pdf"
    helper TudlaAccounting::ApplicationHelper, TudlaAccounting::EntriesHelper, TudlaAccounting::ReportsHelper, TudlaAccounting::DocumentsHelper
    helper do
      # The organization the PDF is for (PdfMaker gives it), as the pages have it, so its
      # amounts are written as the pages write them.
      def accounting_organization = @organization
    end
  end
end
