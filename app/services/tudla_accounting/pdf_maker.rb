# frozen_string_literal: true

module TudlaAccounting
  # Makes the PDFs that go to customers and suppliers, from the same partials the pages
  # print, in headless Chrome (the ferrum gem), or by the pdf_renderer setting (see
  # TudlaAccounting.pdf?):
  #
  #   PdfMaker.document(invoice)                       # an invoice, bill or credit note
  #   PdfMaker.statements([statement], open_items: false)
  #   PdfMaker.payment(payment)                        # a receipt, or a payment notice
  #   PdfMaker.book(books, books.book("sales"))        # a book of accounts, a page to a sheet
  #   PdfMaker.supplier_certificates(report, certificates) # tax certificates, on their form's paper
  #
  # Each returns the PDF's bytes. The page is rendered with the engine's styles inline and
  # the browser is barred from fetching anything, so nothing in it reaches the network.
  # The browser, paper and stylesheet come from the pdf_* settings. Error (a Ferrum error or
  # the renderer's underneath) when it can't be made.
  module PdfMaker
    class Error < StandardError; end

    module_function

    def document(document)
      render("tudla_accounting/documents/document", { document: document }, title: "#{document.title} – #{document.contact.name}", organization: document.organization)
    end

    def statements(statements, open_items:)
      render("tudla_accounting/reports/party_statement", { open_items: open_items }, collection: statements, as: :statement, title: -> { TudlaAccounting.t("reports.party_statement.title") },
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
                                                                                                                paper: [ 8.5, 13 ], margin: 0.3)
    end

    # A payment summary for each payee: what the payer paid it and withheld over the
    # report's months, a page each. See Reports::PayeePayments.
    def payment_summaries(report, payees)
      render("tudla_accounting/reports/payment_summary", { report: report }, collection: payees, as: :payee, title: -> { TudlaAccounting.t("reports.payment_summary.title") }, organization: report.organization)
    end

    # The PDF of a partial, in the PDF layout, for an organization's amounts, in its
    # language (the locale setting). title: can be a callable, to read in that language.
    def render(partial, locals, title:, organization:, landscape: false, paper: nil, margin: 0.5, **options)
      raise Error, "PDFs need the ferrum gem or the pdf_renderer setting" unless TudlaAccounting.pdf?

      html = TudlaAccounting.with_locale(organization) do
        PdfViewsController.render(template: "tudla_accounting/pdf_views/page", layout: "tudla_accounting/pdf", assigns: { title: title.respond_to?(:call) ? title.call : title, organization: organization },
                                  locals: { partial: partial, locals: locals, **options })
      end
      from_html(html, landscape: landscape, paper: paper, margin: margin, organization: organization)
    end

    # The PDF of a page's HTML, on the organization's paper (pdf_paper) unless paper: says
    # (a size by name, or [width, height] in inches), by the pdf_renderer setting or ferrum.
    def from_html(html, landscape: false, paper: nil, margin: 0.5, organization: nil)
      paper ||= TudlaAccounting.configuration.pdf_paper_for(organization)
      renderer = TudlaAccounting.configuration.pdf_renderer
      renderer ? by_renderer(renderer, html, paper: paper, landscape: landscape, margin: margin) : in_chrome(html, paper: paper, landscape: landscape, margin: margin)
    end

    def by_renderer(renderer, html, **page)
      pdf = renderer.call(html, **page)
      raise Error, "The PDF couldn't be made (the pdf_renderer gave #{pdf.class.name}, not the PDF's bytes)" unless pdf.is_a?(String) && pdf.present?

      pdf.b.freeze
    rescue Error
      raise
    rescue StandardError => e
      raise Error, "The PDF couldn't be made (#{e.message})"
    end

    def in_chrome(html, paper:, landscape:, margin:)
      browser = Ferrum::Browser.new(**{ timeout: 30 }.merge(TudlaAccounting.configuration.pdf_browser_options.to_h))
      begin
        page = browser.create_page
        page.network.blocklist = [ /./ ]
        page.content = html
        size = paper.is_a?(Array) ? { paper_width: paper.first, paper_height: paper.last } : { format: paper }
        page.pdf(encoding: :binary, **size, landscape: landscape, print_background: true,
                 margin_top: margin, margin_bottom: margin, margin_left: margin, margin_right: margin)
      ensure
        browser.quit
      end
    rescue Ferrum::Error => e
      raise Error, "The PDF couldn't be made (#{e.message})"
    end

    BUILT_STYLESHEET = Engine.root.join("app/assets/builds/tudla_accounting.css")

    # The CSS with the engine's styles: the pdf_stylesheet setting (a path, or a callable
    # returning the CSS), else the engine's own built stylesheet.
    def stylesheet
      setting = TudlaAccounting.configuration.pdf_stylesheet
      return setting.call.to_s if setting.respond_to?(:call)

      File.read(setting || BUILT_STYLESHEET, encoding: "UTF-8")
    end
  end
end
