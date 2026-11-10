require "rails_helper"
require_relative "../support/system"
require_relative "../support/configuration"

RSpec.describe "Switching theme", type: :system do
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }

  before { sign_in_as(organization) }

  def html_theme = page.evaluate_script("document.documentElement.getAttribute('data-theme')")
  def saved_theme = page.evaluate_script("localStorage.getItem('theme')")

  it "switches between light and dark, remembering the choice across pages" do
    page.execute_script("localStorage.setItem('theme', 'light')")
    visit root_path
    expect(page).to have_button("Switch to dark theme")
    expect(html_theme).to eq("light")

    expect(page).to have_css("[data-theme-target=moon]:not([hidden])", visible: :all)
    expect(page).to have_css("[data-theme-target=sun][hidden]", visible: :all)

    click_button "Switch to dark theme"
    expect(find_button("Switch to light theme")["aria-pressed"]).to eq("true")
    expect(page).to have_css("[data-theme-target=sun]:not([hidden])", visible: :all)
    expect(page).to have_css("[data-theme-target=moon][hidden]", visible: :all)
    expect([ html_theme, saved_theme ]).to eq(%w[dark dark])

    visit accounts_path
    expect(html_theme).to eq("dark")
    expect(page).to have_button("Switch to light theme")

    click_button "Switch to light theme"
    expect([ html_theme, saved_theme ]).to eq(%w[light light])
  end

  describe "with the theme_storage_key setting" do
    include_context "with isolated TudlaAccounting configuration"

    it "keeps the choice under the host's key" do
      TudlaAccounting.configuration.theme_storage_key = "colour-scheme"
      page.execute_script("localStorage.setItem('colour-scheme', 'dark')")
      visit root_path
      expect(page).to have_button("Switch to light theme")
      click_button "Switch to light theme"
      expect(page).to have_button("Switch to dark theme")
      expect(page.evaluate_script("[localStorage.getItem('colour-scheme'), localStorage.getItem('theme')]")).to eq([ "light", nil ])
    end

    it "keeps no choice without one, following the operating system until switched" do
      TudlaAccounting.configuration.theme_storage_key = ""
      page.execute_script("localStorage.setItem('theme', 'light')")
      visit root_path
      expect(html_theme).to be_nil
      find("button[data-controller=theme]").click
      expect(html_theme).to be_present
      expect(saved_theme).to eq("light") # left as the host saved it
    end
  end
end
