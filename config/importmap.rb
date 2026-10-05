# The engine's JavaScript, added to the host app's import map by the
# "tudla_accounting.importmap" initializer. Stimulus comes from stimulus-rails.
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin "tudla_accounting/application"
pin_all_from TudlaAccounting::Engine.root.join("app/javascript/tudla_accounting/controllers"),
             under: "tudla_accounting/controllers", to: "tudla_accounting/controllers"
