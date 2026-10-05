class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  helper_method :current_organization

  private

  # Stand-in for a real host app's login: the organization picked on /sessions/new.
  def current_organization
    @current_organization ||= Organization.find_by(id: session[:organization_id])
  end
end
