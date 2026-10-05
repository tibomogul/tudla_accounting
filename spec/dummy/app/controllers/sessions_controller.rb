# Stand-in login for the dummy app: pick the organization whose books to open.
class SessionsController < ApplicationController
  def new
    @organizations = Organization.order(:name)
  end

  def create
    session[:organization_id] = Organization.find(params[:organization_id]).id
    redirect_to tudla_accounting.root_path
  end

  def destroy
    session.delete(:organization_id)
    redirect_to new_session_path
  end
end
