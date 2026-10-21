# frozen_string_literal: true

module TudlaAccounting
  # Makes the PDFs that go to customers and suppliers, from the same partials the pages
  # print, in headless Chrome (the ferrum gem; see TudlaAccounting.pdf?):
  #
  #   PdfMaker.document(invoice)                       # an invoice, bill or credit note
  #   PdfMaker.statements([statement], open_items: false)
  #   PdfMaker.payment(payment)                        # a receipt, or a payment notice
  #
  # Each returns the PDF's bytes. The page is rendered with the engine's styles inline and
  # the browser is barred from fetching anything, so nothing in it reaches the network.
  # The browser, paper and stylesheet come from the pdf_* settings. Error (a Ferrum error
  # underneath, or no stylesheet) when it can't be made.
  module PdfMaker
    class Error < StandardError; end

    module_function

    def document(document)
      render("tudla_accounting/documents/document", { document: document }, title: "#{document.title} – #{document.contact.name}")
    end

    def statements(statements, open_items:)
      render("tudla_accounting/reports/party_statement", { open_items: open_items }, collection: statements, as: :statement, title: "Statement of account")
    end

    def payment(payment)
      render("tudla_accounting/payments/notice", { payment: payment }, title: payment.title)
    end

    # The PDF of a partial, in the PDF layout.
    def render(partial, locals, title:, **options)
      raise Error, "PDFs need the ferrum gem" unless TudlaAccounting.pdf?

      html = PdfViewsController.render(template: "tudla_accounting/pdf_views/page", layout: "tudla_accounting/pdf", assigns: { title: title },
                                       locals: { partial: partial, locals: locals, **options })
      from_html(html)
    end

    def from_html(html)
      settings = TudlaAccounting.configuration
      browser = Ferrum::Browser.new(**{ timeout: 30 }.merge(settings.pdf_browser_options.to_h))
      begin
        page = browser.create_page
        page.network.blocklist = [ /./ ]
        page.content = html
        page.pdf(encoding: :binary, format: settings.pdf_paper.to_sym, print_background: true,
                 margin_top: 0.5, margin_bottom: 0.5, margin_left: 0.5, margin_right: 0.5)
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
