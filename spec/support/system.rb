# Browser specs (type: :system) run in headless Chrome inside the container.
# Buttons and fields can be found by their aria-label too, as assistive tech finds them.
Capybara.enable_aria_label = true

RSpec.configure do |config|
  config.before(:each, type: :system) do
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1000 ] do |options|
      options.add_argument("--no-sandbox")            # Chrome's sandbox needs privileges the container lacks
      options.add_argument("--disable-dev-shm-usage") # /dev/shm is small in Docker
    end
  end
end

module SystemSpecHelpers
  # Opens an organization's books through the dummy app's stand-in login, in the browser.
  def sign_in_as(organization)
    visit "/session/new"
    click_button "#{organization.name} (#{organization.currency})"
    expect(page).to have_current_path(root_path) # the redirect has landed, so the queries below can't catch the login page
    expect(page).to have_css("h1", text: "Dashboard")
  end

  # For a click that comes back to the same URL, where have_current_path can't tell the new
  # page has loaded: a mark on the old page's window can, as each click loads a whole page.
  def click_button_and_reload(name)
    page.execute_script("window.tcPageBeforeClick = true")
    click_button name
    page.document.synchronize do
      raise Capybara::ExpectationNotMet, "the page didn't reload" if page.evaluate_script("window.tcPageBeforeClick")
    end
  end
end

RSpec.configure { |config| config.include SystemSpecHelpers, type: :system }
