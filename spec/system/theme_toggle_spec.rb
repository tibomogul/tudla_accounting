require "rails_helper"
require_relative "../support/system"

RSpec.describe "Switching theme", type: :system do
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }

  before { sign_in_as(organization) }

  def html_theme = page.evaluate_script("document.documentElement.getAttribute('data-theme')")
  def saved_theme = page.evaluate_script("localStorage.getItem('theme')")

  it "switches between light and dark, remembering the choice across pages" do
    page.execute_script("localStorage.setItem('theme', 'light')")
    visit "/tudla_accounting/"
    expect(page).to have_button("Switch to dark theme")
    expect(html_theme).to eq("light")

    expect(page).to have_css("[data-theme-target=moon]:not([hidden])", visible: :all)
    expect(page).to have_css("[data-theme-target=sun][hidden]", visible: :all)

    click_button "Switch to dark theme"
    expect(find_button("Switch to light theme")["aria-pressed"]).to eq("true")
    expect(page).to have_css("[data-theme-target=sun]:not([hidden])", visible: :all)
    expect(page).to have_css("[data-theme-target=moon][hidden]", visible: :all)
    expect([ html_theme, saved_theme ]).to eq(%w[dark dark])

    visit "/tudla_accounting/accounts"
    expect(html_theme).to eq("dark")
    expect(page).to have_button("Switch to light theme")

    click_button "Switch to light theme"
    expect([ html_theme, saved_theme ]).to eq(%w[light light])
  end
end
