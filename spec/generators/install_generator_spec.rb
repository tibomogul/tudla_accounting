require "rails_helper"
require "generators/tudla_accounting/install/install_generator"

RSpec.describe TudlaAccounting::Generators::InstallGenerator do
  let(:root) { Dir.mktmpdir }
  let(:css) { File.join(root, "app/assets/tailwind/application.css") }

  before do
    FileUtils.mkdir_p(File.join(root, "config"))
    File.write(File.join(root, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
    FileUtils.mkdir_p(File.dirname(css))
    File.write(css, %(@import "tailwindcss";\n))
  end

  after { FileUtils.remove_entry(root) }

  let(:rakes) { [] }

  # Runs the generator as `rails generate` would, recording rake tasks instead of running them.
  def generate(*args)
    output = StringIO.new
    $stdout, original = output, $stdout
    options = Thor::Options.new(described_class.class_options).parse(args)
    generator = described_class.new([], options, destination_root: root)
    allow(generator).to receive(:rake) { |task| rakes << task }
    generator.invoke_all
    output.string
  ensure
    $stdout = original
  end

  def read(path) = File.read(File.join(root, path))

  it "writes the initializer, mounts the engine and copies its migrations, leaving the app's styles alone" do
    output = generate

    initializer = read("config/initializers/tudla_accounting.rb")
    expect(initializer).to include("TudlaAccounting.configure do |config|", "# --- Pages (mounted at /accounting) ---", "config.authorize")
    expect { RubyVM::InstructionSequence.compile(initializer) }.not_to raise_error
    expect(read("config/routes.rb")).to include(%(mount TudlaAccounting::Engine => "/accounting"))
    expect(File.read(css)).to eq(%(@import "tailwindcss";\n))
    expect(output).to include("TudlaAccounting is installed", "Open /accounting once signed in", "bin/rails active_storage:install")
    expect(rakes).to eq([ "tudla_accounting:install:migrations" ])
  end

  it "takes another mount path, and can skip migrations" do
    generate("--mount-path=/books", "--skip-migrations")

    expect(read("config/routes.rb")).to include(%(mount TudlaAccounting::Engine => "/books"))
    expect(rakes).to be_empty
  end
end
