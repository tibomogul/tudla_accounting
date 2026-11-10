# frozen_string_literal: true

# Builds the engine's pages' JavaScript into one classic script,
# app/assets/builds/tudla_accounting.js, which ships in the gem so host apps need neither
# importmap nor Stimulus: Stimulus itself (stimulus-rails' build, a development dependency),
# amounts.js and each controller, every module in a function of its own, and a Stimulus
# application of the engine's own that registers the controllers by file name
# (budget_grid_controller.js is "budget-grid"). No Node: the modules may only import
# Controller from "@hotwired/stimulus" and named functions from "tudla_accounting/amounts",
# and export functions (amounts) or a default class (controllers); anything else is refused.
#
#   JavascriptBundle.new(root).write   # rake tudla_accounting:js:build
class JavascriptBundle
  class Error < StandardError; end

  OUTPUT = "app/assets/builds/tudla_accounting.js"
  SOURCES = "app/javascript/tudla_accounting"
  AMOUNTS = %w[parseNumber parseUnits formatUnits fieldUnits].freeze

  def initialize(root, stimulus: Gem.loaded_specs.fetch("stimulus-rails").full_gem_path)
    @root = Pathname(root)
    @stimulus = Pathname(stimulus).join("app/assets/javascripts/stimulus.min.js")
    @stimulus_version = Gem.loaded_specs["stimulus-rails"]&.version
  end

  def write(path = @root.join(OUTPUT)) = File.write(path, source)

  def sources = [ @root.join(SOURCES, "amounts.js"), *controllers ]

  def source
    <<~JS
      /* TudlaAccounting's pages, built by rake tudla_accounting:js:build from app/javascript/tudla_accounting. Don't edit.
         Includes Stimulus (from stimulus-rails #{@stimulus_version}), MIT License, Copyright (c) Basecamp, LLC. */
      (() => {
      "use strict";
      const { Application, Controller } = (() => {
      #{stimulus}
      })();
      const { #{AMOUNTS.join(', ')} } = (() => {
      #{amounts}
      })();
      const application = Application.start();
      #{controllers.map { |file| register(file) }.join("\n")}
      })();
    JS
  end

  private

  def controllers = Dir[@root.join(SOURCES, "controllers", "*_controller.js")].sort.map { |file| Pathname(file) }

  # Stimulus's ES module, its closing export turned into a return of the two it needs.
  def stimulus
    code = File.read(@stimulus)
    exports = code[/export\s*\{([^}]*)\};?/, 1] or raise Error, "#{@stimulus} has no export list"
    names = exports.split(",").to_h { |pair| pair.strip.split(/\s+as\s+/).then { |local, name| [ name || local, local ] } }
    locals = %w[Application Controller].map { |name| "#{name}: #{names.fetch(name) { raise Error, "Stimulus doesn't export #{name}" }}" }
    code.sub(/export\s*\{[^}]*\};?/, "return { #{locals.join(', ')} };").sub(%r{^//# sourceMappingURL=.*$}, "")
  end

  def amounts
    code = File.read(sources.first)
    exported = code.scan(/^export function (\w+)/).flatten
    raise Error, "amounts.js exports #{exported.sort.join(', ')}; the bundle expects #{AMOUNTS.sort.join(', ')}" unless exported.sort == AMOUNTS.sort

    checked(code.gsub(/^export function /, "function "), "amounts.js") + "\nreturn { #{AMOUNTS.join(', ')} };"
  end

  def register(file)
    code = File.read(file)
    code = code.sub(/^import \{ Controller \} from "@hotwired\/stimulus"\n/, "")
               .sub(/^import \{ ([\w, ]+) \} from "tudla_accounting\/amounts"\n/) { (Regexp.last_match(1).split(/,\s*/) - AMOUNTS).empty? ? "" : raise(Error, "#{file.basename} imports what amounts.js doesn't export") }
    raise Error, "#{file.basename} has no export default class" unless code.sub!(/^export default class /, "const controller = class ")

    name = file.basename("_controller.js").to_s.tr("_", "-")
    %(application.register("#{name}", (() => {\n#{checked(code, file.basename)}\nreturn controller;\n})());)
  end

  def checked(code, name)
    raise Error, "#{name} has an import or export the bundle can't take" if code.match?(/^\s*(import|export)\b/)

    code
  end
end
