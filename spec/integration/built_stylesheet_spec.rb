require "rails_helper"
require "open3"
require "tailwindcss/ruby"
require_relative "../support/configuration"
require_relative "../support/sign_in"

# The pages' stylesheet ships built (app/assets/builds/tudla_accounting.css), so host apps
# need no Tailwind. It must have every class the views, helpers and Stimulus controllers use.
RSpec.describe "The engine's built stylesheet" do
  let(:built) { TudlaAccounting::Engine.root.join("app/assets/builds/tudla_accounting.css") }

  it "is up to date with its sources (rake tudla_accounting:css:build)" do
    Dir.mktmpdir do |dir|
      out = File.join(dir, "tudla_accounting.css")
      _output, status = Open3.capture2e(Tailwindcss::Ruby.executable, "-i", TudlaAccounting::Engine.root.join("app/assets/tailwind/tudla_accounting/engine.css").to_s,
                                        "-o", out, "--minify", chdir: TudlaAccounting::Engine.root.to_s)
      expect(status).to be_success
      expect(File.read(out) == File.read(built)).to be(true), "app/assets/builds/tudla_accounting.css is out of date: run bundle exec rake tudla_accounting:css:build"
    end
  end

  describe "on the pages", type: :request do
    include_context "with isolated TudlaAccounting configuration"

    let(:organization) { create(:organization, name: "Acme", currency: "AUD") }

    before { sign_in_as(organization) }

    it "is linked, and then the host's page_stylesheets, but not the host's Tailwind build" do
      TudlaAccounting.configuration.page_stylesheets = [ "application", "" ]
      get TudlaAccounting::Engine.routes.url_helpers.root_path
      links = Nokogiri::HTML(response.body).css("link[rel=stylesheet]").map { |link| link["href"] }
      expect(links).to match([ %r{/tudla_accounting-\w+\.css\z}, %r{/application-\w+\.css\z} ])
      expect(TudlaAccounting.configuration.page_stylesheets).to eq(%w[application])
    end
  end
end
