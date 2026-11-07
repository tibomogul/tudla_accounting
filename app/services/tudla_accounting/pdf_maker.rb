# frozen_string_literal: true

module TudlaAccounting
  # Makes the PDFs that go to customers and suppliers, from the same partials the pages
  # print, in headless Chrome (the ferrum gem; see TudlaAccounting.pdf?):
  #
  #   PdfMaker.document(invoice)                       # an invoice, bill or credit note
  #   PdfMaker.statements([statement], open_items: false)
  #   PdfMaker.payment(payment)                        # a receipt, or a payment notice
  #   PdfMaker.book(books, books.book("sales"))        # a book of accounts, a page to a sheet
  #   PdfMaker.supplier_certificates(report, certificates) # tax certificates, on their form's paper
  #
  # Each returns the PDF's bytes. The page is rendered with the engine's styles inline and
  # the browser is barred from fetching anything, so nothing in it reaches the network.
  # The browser, paper and stylesheet come from the pdf_* settings. Error (a Ferrum error
  # underneath, or no stylesheet) when it can't be made.
  module PdfMaker
    class Error < StandardError; end

    module_function

    def document(document)
      render("tudla_accounting/documents/document", { document: document }, title: "#{document.title} – #{document.contact.name}", organization: document.organization)
    end

    def statements(statements, open_items:)
      render("tudla_accounting/reports/party_statement", { open_items: open_items }, collection: statements, as: :statement, title: "Statement of account",
                                                                                     organization: statements.first&.organization)
    end

    def payment(payment)
      render("tudla_accounting/payments/notice", { payment: payment }, title: payment.title, organization: payment.organization)
    end

    # Its wider books (more than six columns) on landscape paper.
    def book(books, book)
      render("tudla_accounting/reports/book_page", { book: book, books: books }, collection: book.pages, as: :page, title: book.title,
                                                                                organization: books.organization, landscape: book.columns.size > 6)
    end

    # BIR Form 2307s, a sheet each, on the 8.5 x 13 inch paper the form is laid out for,
    # whatever pdf_paper says. See Reports::SupplierCertificates.
    def supplier_certificates(report, certificates)
      render("tudla_accounting/reports/supplier_certificates", { report: report, certificates: certificates }, title: "BIR Form 2307", organization: report.organization,
                                                                                                                paper: { paper_width: 8.5, paper_height: 13 }, margin: 0.3)
    end

    # A payment summary for each payee: what the payer paid it and withheld over the
    # report's months, a page each. See Reports::PayeePayments.
    def payment_summaries(report, payees)
      render("tudla_accounting/reports/payment_summary", { report: report }, collection: payees, as: :payee, title: "Payment summary", organization: report.organization)
    end

    # The PDF of a partial, in the PDF layout, for an organization's amounts.
    def render(partial, locals, title:, organization:, landscape: false, paper: nil, margin: 0.5, **options)
      raise Error, "PDFs need the ferrum gem" unless TudlaAccounting.pdf?

      html = PdfViewsController.render(template: "tudla_accounting/pdf_views/page", layout: "tudla_accounting/pdf", assigns: { title: title, organization: organization },
                                       locals: { partial: partial, locals: locals, **options })
      from_html(html, landscape: landscape, paper: paper, margin: margin, organization: organization)
    end

    # The PDF of a page's HTML, on the organization's paper (pdf_paper) unless paper: says.
    def from_html(html, landscape: false, paper: nil, margin: 0.5, organization: nil)
      settings = TudlaAccounting.configuration
      browser = Ferrum::Browser.new(**{ timeout: 30 }.merge(settings.pdf_browser_options.to_h))
      begin
        page = browser.create_page
        page.network.blocklist = [ /./ ]
        page.content = html
        page.pdf(encoding: :binary, **(paper || { format: settings.pdf_paper_for(organization) }), landscape: landscape, print_background: true,
                 margin_top: margin, margin_bottom: margin, margin_left: margin, margin_right: margin)
      ensure
        browser.quit
      end
    rescue Ferrum::Error => e
      raise Error, "The PDF couldn't be made (#{e.message})"
    end

    # The compiled CSS with the engine's styles: the pdf_stylesheet setting (a path, or a
    # callable returning the CSS), else the host's "tailwind.css" asset.
    def stylesheet
      setting = TudlaAccounting.configuration.pdf_stylesheet
      return setting.call.to_s if setting.respond_to?(:call)
      return File.read(setting, encoding: "UTF-8") if setting

      asset = Rails.application.respond_to?(:assets) && Rails.application.assets.respond_to?(:load_path) && Rails.application.assets.load_path.find("tailwind.css")
      raise Error, "PDFs need the compiled stylesheet: build tailwind.css, or set pdf_stylesheet" unless asset

      asset.content.dup.force_encoding(Encoding::UTF_8) # read as bytes
    end
  end
end
