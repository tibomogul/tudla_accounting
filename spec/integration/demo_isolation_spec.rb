require "rails_helper"
require "open3"

# The dummy app doubles as the demo, but the engine's specs boot it without the demo:
# no Demo code or routes, only the harness (Organization, the stand-in login). See
# config.x.demo in spec/dummy/config/application.rb.
RSpec.describe "Demo isolation" do
  # Booted in a child process, as the engine's run boots it, so that eager loading all
  # of the dummy app doesn't change what the rest of this run has loaded. The sign-in
  # hooks must keep their defaults: no partial, and every organization listed.
  it "boots the dummy app without the demo" do
    script = <<~RUBY
      Rails.application.eager_load!
      routes = Rails.application.routes.routes.map { |route| route.path.spec.to_s }
      organizations = Organization.order(:name)
      puts({
        demo: Rails.configuration.x.demo, defined: !defined?(::Demo).nil?, routes: routes.grep(%r{\\A/demo}),
        sign_in_partial: Rails.configuration.x.sign_in_partial,
        sign_in_organizations: Rails.configuration.x.sign_in_organizations.call(organizations).equal?(organizations)
      }.to_json)
    RUBY
    output, status = Open3.capture2e({ "RAILS_ENV" => "test", "TUDLA_DEMO" => nil }, Rails.root.join("bin/rails").to_s, "runner", script, chdir: Rails.root.to_s)

    expect(status).to be_success, output
    expect(JSON.parse(output.lines.last)).to eq(
      "demo" => false, "defined" => false, "routes" => [], "sign_in_partial" => nil, "sign_in_organizations" => true
    )
  end

  # Booting only proves nothing loads the demo; engine or harness code could still name
  # it on a path that boot doesn't take, and its views aren't autoloaded, so a harness
  # view could render one. The dummy app's wiring (config/application.rb,
  # config/routes.rb), its seeds and the demo's own files may name it.
  it "keeps the engine's and the harness's code from naming the demo" do
    root = TudlaAccounting::Engine.root
    dummy = root.join("spec/dummy")
    extensions = "{rb,erb,rake,js,css,yml}"
    engine = root.glob("{app,lib,config,db,spec}/**/*.#{extensions}").reject { |file| file.to_s.start_with?("#{dummy}/") || file.to_s == __FILE__ }
    wiring = %w[config/application.rb config/routes.rb config/initializers/demo.rb db/seeds.rb].map { |path| dummy.join(path) }
    harness = dummy.glob("{app,config,db}/**/*.#{extensions}").reject do |file|
      file.to_s.match?(%r{/app/\w+/demo/}) || wiring.include?(file)
    end

    # Its namespace, its route helpers, the switch itself, or its views and paths
    # ("demo/sessions/button", "/demo/session").
    reference = /\bDemo::|\bmodule Demo\b|\bdemo_\w*(?:path|url)\b|\bx\.demo\b|["'\/]demo(?:\/|["'])/
    naming = (engine + harness).select { |file| file.read.match?(reference) }
    expect(naming.map { |file| file.relative_path_from(root).to_s }).to be_empty,
      "These engine or harness files name the demo (#{reference.inspect}): #{naming.map { |file| file.relative_path_from(root) }.join(', ')}. " \
      "Only the demo's own files and the dummy app's wiring may; the harness offers hooks instead (CLAUDE.md, \"Dummy app: harness and demo\")."
  end
end
