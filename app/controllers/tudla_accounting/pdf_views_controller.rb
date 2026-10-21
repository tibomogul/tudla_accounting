module TudlaAccounting
  # Renders the pages PDFs are made from, outside any request (from a job, say): no
  # routes, no host controller, no sign-in. Its views get what they show through locals.
  # See PdfMaker.
  class PdfViewsController < ActionController::Base
    layout "tudla_accounting/pdf"
    helper TudlaAccounting::ApplicationHelper, TudlaAccounting::EntriesHelper, TudlaAccounting::ReportsHelper, TudlaAccounting::DocumentsHelper
  end
end
