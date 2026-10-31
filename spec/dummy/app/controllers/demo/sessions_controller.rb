# One click into the demo: seeds its books if they aren't there yet and opens them, Demo
# Co's (in dollars) or, with books=euro, Demo GmbH's (in euros). The first click seeds
# the entries inside the request, which takes a few seconds; that's fine for a demo.
class Demo::SessionsController < ApplicationController
  SEEDERS = { "euro" => Demo::EuroSeeder }.freeze

  def create
    session[:organization_id] = SEEDERS.fetch(params[:books], Demo::Seeder).call.id
    redirect_to tudla_accounting.root_path
  end
end
