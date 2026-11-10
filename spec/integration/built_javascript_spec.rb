require "rails_helper"
require_relative "../../tasks/javascript_bundle"

# The pages' JavaScript ships built (app/assets/builds/tudla_accounting.js), with its own
# Stimulus, so host apps need neither importmap nor Stimulus.
RSpec.describe JavascriptBundle do
  let(:root) { TudlaAccounting::Engine.root }

  it "is up to date with its sources (rake tudla_accounting:js:build)" do
    expect(described_class.new(root).source == File.read(root.join(described_class::OUTPUT))).to be(true),
           "#{described_class::OUTPUT} is out of date: run bundle exec rake tudla_accounting:js:build"
  end

  it "registers each controller by its file's name, in one script that imports nothing" do
    source = described_class.new(root).source
    names = Dir[root.join("app/javascript/tudla_accounting/controllers/*_controller.js")].map { |file| File.basename(file, "_controller.js").tr("_", "-") }
    expect(source.scan(/application\.register\("([\w-]+)"/).flatten).to match_array(names)
    expect(source).not_to match(/^\s*(import|export)\b/)
    expect(source).to include("MIT License", "Basecamp")
  end

  describe "refusing what it can't bundle" do
    let(:copy) { Pathname(Dir.mktmpdir) }

    before { FileUtils.cp_r(root.join("app/javascript"), copy.join("app/javascript").tap { |dir| dir.dirname.mkpath }) }
    after { FileUtils.remove_entry(copy) }

    def controller(name) = copy.join("app/javascript/tudla_accounting/controllers/#{name}_controller.js")
    def bundled = described_class.new(copy).source

    it "takes only Stimulus's Controller and amounts.js's functions" do
      File.write(controller("extra"), %(import { Controller } from "@hotwired/stimulus"\nimport { debounce } from "lodash"\nexport default class extends Controller {}\n))
      expect { bundled }.to raise_error(described_class::Error, "extra_controller.js has an import or export the bundle can't take")

      File.write(controller("extra"), %(import { Controller } from "@hotwired/stimulus"\nimport { parseUnits, roundUnits } from "tudla_accounting/amounts"\nexport default class extends Controller {}\n))
      expect { bundled }.to raise_error(described_class::Error, "extra_controller.js imports what amounts.js doesn't export")
    end

    it "needs a default class from a controller and amounts.js's functions as it knows them" do
      File.write(controller("extra"), %(import { Controller } from "@hotwired/stimulus"\nexport class Extra extends Controller {}\n))
      expect { bundled }.to raise_error(described_class::Error, "extra_controller.js has no export default class")

      File.delete(controller("extra"))
      amounts = copy.join("app/javascript/tudla_accounting/amounts.js")
      File.write(amounts, File.read(amounts) + "\nexport function roundUnits(units) { return units }\n")
      expect { bundled }.to raise_error(described_class::Error, /amounts.js exports fieldUnits, formatUnits, parseNumber, parseUnits, roundUnits; the bundle expects/)

      File.write(amounts, File.read(amounts).sub("export function roundUnits", "function roundUnits") + "export const rate = 1\n")
      expect { bundled }.to raise_error(described_class::Error, "amounts.js has an import or export the bundle can't take")
    end

    it "needs Stimulus's export list" do
      stimulus = copy.join("stimulus/app/assets/javascripts/stimulus.min.js").tap { |file| file.dirname.mkpath }
      File.write(stimulus, "class e{}")
      expect { described_class.new(copy, stimulus: copy.join("stimulus")).source }.to raise_error(described_class::Error, /has no export list/)
      File.write(stimulus, "class e{};export{e as Application};")
      expect { described_class.new(copy, stimulus: copy.join("stimulus")).source }.to raise_error(described_class::Error, "Stimulus doesn't export Controller")
    end

    it "writes the bundle" do
      out = copy.join("bundle.js")
      described_class.new(copy).write(out)
      expect(File.read(out)).to start_with("/* TudlaAccounting's pages")
    end
  end
end
