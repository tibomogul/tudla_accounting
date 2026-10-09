# One click into the demo: seeds Demo Co if it isn't there yet and opens its books.
# The first click seeds a couple of hundred entries inside the request, which takes a
# few seconds; that's fine for a demo.
class Demo::SessionsController < ApplicationController
  def create
    session[:organization_id] = Demo::Seeder.call.id
    redirect_to tudla_accounting.root_path
  end
end
