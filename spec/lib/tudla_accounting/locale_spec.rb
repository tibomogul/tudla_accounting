require "rails_helper"
require_relative "../../support/configuration"

# The wording of emails (and PDFs) comes from config/locales/en.yml, in each organization's
# locale; a host's locale files can change it or translate it.
RSpec.describe "The engine's wording and languages" do
  include_context "with isolated TudlaAccounting configuration"

  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:config) { TudlaAccounting.configuration }

  around do |example|
    locales = I18n.available_locales
    I18n.available_locales = [ :en, :fr ]
    I18n.backend.store_translations(:fr, date: { abbr_month_names: [ nil, "janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc." ],
                                                 formats: { tudla_accounting_day: "%-d %b %Y" } },
                                         tudla_accounting: { email_templates: { invoice: { subject: "Facture %{number} de %{organization}, à payer le %{due_on}" } } })
    example.run
  ensure
    I18n.backend.reload!
    I18n.available_locales = locales
  end

  it "is the default locale's, or the organization's from the locale setting" do
    expect(config.locale_for(organization)).to eq(:en)
    config.locale = ->(org) { org.currency == "AUD" ? "fr" : nil }
    expect(config.locale_for(organization)).to eq(:fr)
    config.locale = "de"
    expect { config.locale_for(organization) }.to raise_error(ArgumentError, /locale gave :de for .*; the app's I18n.available_locales are en, fr/)
  end

  it "writes an organization's emails in its language, falling back to the default locale's text where a translation is missing" do
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([ { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "4000", name: "Sales", category: "income" } ], organization)
    contact = TudlaAccounting::Contact.create!(organization: organization, name: "Northwind")
    invoice = TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: contact, issued_on: Date.new(2026, 2, 1), due_on: Date.new(2026, 2, 28),
                                                lines_attributes: [ { description: "Work", unit_price_cents: 10_00, account: TudlaAccounting::Account.find_by!(organization: organization, code: "4000") } ]).approve!
    config.locale = :fr
    draft = TudlaAccounting::EmailDraft.for_document(invoice)
    expect(draft[:subject_line]).to eq("Facture INV-0001 de Acme, à payer le 28 févr. 2026")
    expect(draft[:message]).to start_with("Hello Northwind,").and(include("due on 28 févr. 2026")) # no French body: the English one, French dates
    expect(I18n.locale).to eq(:en)

    config.document_email_templates = { invoice: { body: "Bonjour %{contact}" } }
    expect(TudlaAccounting::EmailDraft.for_document(invoice).values_at(:subject_line, :message)).to eq([ "Facture INV-0001 de Acme, à payer le 28 févr. 2026", "Bonjour Northwind" ])
  end

  it "makes an organization's PDFs in its language, from the same layouts the pages show in English" do
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([ { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "4000", name: "Sales", category: "income" } ], organization)
    contact = TudlaAccounting::Contact.create!(organization: organization, name: "Northwind")
    invoice = TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: contact, issued_on: Date.new(2026, 2, 1), due_on: Date.new(2026, 2, 28),
                                                lines_attributes: [ { description: "Work", unit_price_cents: 10_00, account: TudlaAccounting::Account.find_by!(organization: organization, code: "4000") } ]).approve!
    I18n.backend.store_translations(:fr, tudla_accounting: { document_kinds: { sales_invoice: "Facture" }, documents: { document: { total: "Total TTC", due: "Échéance" } } })
    pages = []
    config.pdf_renderer = lambda do |html, **|
      pages << Nokogiri::HTML(html).at("[data-document]").text.squish
      "%PDF"
    end
    config.locale = :fr
    TudlaAccounting::PdfMaker.document(invoice)
    expect(pages.last).to include("Facture", "Échéance28 févr. 2026", "Total TTC", "Description") # Description isn't translated: English
    expect(I18n.locale).to eq(:en)

    html = TudlaAccounting::PdfViewsController.render(partial: "tudla_accounting/documents/document", locals: { document: invoice })
    expect(Nokogiri::HTML(html).text.squish).to include("Invoice", "Due28 Feb 2026", "Total")
  end

  it "has every key it reads in English" do
    expect(TudlaAccounting::Configuration.locale_email_templates(:en).keys).to eq(TudlaAccounting::Configuration::DOCUMENT_EMAIL_KINDS)
    expect(TudlaAccounting.day(Date.new(2026, 11, 6))).to eq("6 Nov 2026")
    expect { TudlaAccounting.t("email_templates.fax.subject") }.to raise_error(I18n::MissingTranslationData)
  end
end

RSpec.describe "The PDFs' wording" do
  include_context "with isolated TudlaAccounting configuration"

  let(:partials) { %w[documents/_document payments/_notice reports/_party_statement reports/_payment_summary] }

  it "has every key the PDF layouts read in English" do
    keys = partials.flat_map do |partial|
      source = File.read(TudlaAccounting::Engine.root.join("app/views/tudla_accounting/#{partial}.html.erb"))
      scope = partial.tr("/", ".").sub(/\._?/, ".").sub("._", ".")
      source.scan(/tc_t\(([^%]*?)\)\s*(?:%>|\)|,|if|\.)/).flatten.flat_map { |call| call.scan(/"(\.?[a-z_.]+)"/).flatten }
            .map { |key| key.start_with?(".") ? "#{scope}#{key}" : key }
    end
    expect(keys.size).to be > 80
    expect(keys.reject { |key| I18n.exists?("tudla_accounting.#{key}", :en) }).to eq([])
    %w[statement_kinds aging_buckets document_kinds].each { |group| expect(I18n.t("tudla_accounting.#{group}")).to be_a(Hash) }
    expect(TudlaAccounting::PartyStatement::KINDS.keys + %i[reversal adjustment]).to match_array(I18n.t("tudla_accounting.statement_kinds").keys)
    expect(TudlaAccounting::ReportsHelper::AGING_BUCKETS.keys).to eq(I18n.t("tudla_accounting.aging_buckets").keys)
    expect(TudlaAccounting::Document::KINDS.keys.map(&:to_sym)).to eq(I18n.t("tudla_accounting.document_kinds").keys)
  end
end
