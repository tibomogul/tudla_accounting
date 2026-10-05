# Opens an organization's books through the dummy app's stand-in login.
module SignInHelpers
  def sign_in_as(organization)
    post Rails.application.routes.url_helpers.session_path(organization_id: organization.id)
  end
end

RSpec.configure { |config| config.include SignInHelpers, type: :request }
