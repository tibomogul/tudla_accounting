require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Country pieces", type: :request do
  include_context "with isolated TudlaAccounting configuration"

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:philippine_pages) { %i[reports_books_path reports_books_sample_path reports_sales_list_path reports_purchases_list_path reports_withholding_path reports_qap_path reports_sawt_path reports_supplier_certificates_path] }
  let(:australian_pages) { %i[reports_payee_payments_path reports_taxable_payments_path] }

  before do
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([ { code: "2200", name: "GST", category: "liability" }, { code: "2350", name: "Withholding", category: "liability" } ], organization)
  end

  def country(code) = TudlaAccounting.configuration.country = ->(_organization) { code }
  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)

  it "opens a country's report pages only for its books, or books with no country" do
    { nil => philippine_pages + australian_pages, "PH" => philippine_pages, "AU" => australian_pages, "DE" => [] }.each do |code, open|
      country(code)
      (philippine_pages + australian_pages).each do |page|
        get routes.public_send(page)
        expect(response).to have_http_status(open.include?(page) ? :ok : :not_found), "#{page} for #{code.inspect}"
      end
    end
  end

  it "answers a country's reports in the API only for its books" do
    headers = { "Authorization" => "Bearer #{TudlaAccounting::ApiToken.issue!(organization: organization, name: "Shop", permissions: %w[read]).last}" }
    country("AU")
    %w[qap sales_list].each do |report|
      get routes.api_v1_report_path(report), headers: headers
      expect(response).to have_http_status(:not_found)
    end
    get routes.api_v1_report_path("taxable_payments"), headers: headers
    expect(response).to have_http_status(:ok)
    get routes.api_v1_report_path("trial_balance"), headers: headers
    expect(response).to have_http_status(:ok)
  end

  it "offers the books' country's templates" do
    { nil => [ "au_bas", "uk_vat", "ph_2550q" ], "AU" => [ "au_bas" ], "GB" => [ "uk_vat" ] }.each do |code, templates|
      country(code)
      get routes.new_tax_return_form_path
      expect(css_select("#template option").map { |option| option["value"] }).to eq([ "" ] + templates)
    end
    { nil => [ "ph_expanded", "au_no_abn" ], "PH" => [ "ph_expanded" ] }.each do |code, templates|
      country(code)
      get routes.withholding_codes_path
      expect(css_select("#template option").map { |option| option["value"] }).to eq(templates)
    end
    country("DE")
    get routes.withholding_codes_path
    expect(response.body).not_to include("Add a starter list")
  end

  it "asks for the TPAR flag only in Australian books, and keeps it on a contact that has it" do
    country("PH")
    get routes.new_contact_path
    expect(css_select("input[name='contact[taxable_payments]']")).to be_empty
    flagged = TudlaAccounting::Contact.create!(organization: organization, name: "Bright Spark", kind: "supplier", taxable_payments: true)
    get routes.edit_contact_path(flagged)
    expect(css_select("input[type=checkbox][name='contact[taxable_payments]']")).not_to be_empty
    country("AU")
    get routes.new_contact_path
    expect(css_select("input[type=checkbox][name='contact[taxable_payments]']")).not_to be_empty
  end

  it "asks what a purchase was bought as only in Philippine books, and keeps it on a code that has it" do
    country("AU")
    get routes.new_tax_code_path
    expect(css_select("select[name='tax_code[purchase_type]']")).to be_empty
    code = TudlaAccounting::TaxCode.create!(organization: organization, code: "VAT-S", name: "Services", rate: "0.12", kind: :purchases, account: account("2200"), purchase_type: "services")
    get routes.edit_tax_code_path(code)
    expect(css_select("select[name='tax_code[purchase_type]']")).not_to be_empty
    country("PH")
    get routes.new_tax_code_path
    expect(css_select("select[name='tax_code[purchase_type]']")).not_to be_empty
  end
end
