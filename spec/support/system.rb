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

# Opens an organization's books through the dummy app's stand-in login, in the browser.
module SystemSignInHelpers
  def sign_in_as(organization)
    visit "/session/new"
    click_button "#{organization.name} (#{organization.currency})"
    expect(page).to have_css("h1", text: "Dashboard")
  end
end

RSpec.configure { |config| config.include SystemSignInHelpers, type: :system }
