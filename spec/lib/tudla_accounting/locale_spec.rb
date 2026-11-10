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

  it "has every key it reads in English" do
    expect(TudlaAccounting::Configuration.locale_email_templates(:en).keys).to eq(TudlaAccounting::Configuration::DOCUMENT_EMAIL_KINDS)
    expect(TudlaAccounting.day(Date.new(2026, 11, 6))).to eq("6 Nov 2026")
    expect { TudlaAccounting.t("email_templates.fax.subject") }.to raise_error(I18n::MissingTranslationData)
  end
end
