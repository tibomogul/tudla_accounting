# The engine shows the books of the organization the dummy app's stand-in login picked.
TudlaAccounting.configure do |config|
  config.current_organization = ->(controller) { controller.send(:current_organization) }
  # The dummy app has no users; audit events name the stand-in login instead.
  config.current_actor = ->(_controller) { "Demo user" }
  # Chrome can't sandbox itself in the dummy app's container (nor do the browser specs),
  # and on a busy CI runner can take longer than ferrum's 10 seconds to start.
  config.pdf_browser_options = { browser_options: { "no-sandbox" => nil }, process_timeout: 30 }
end
