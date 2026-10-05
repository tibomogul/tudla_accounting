// Entry point for the engine's pages (javascript_importmap_tags "tudla_accounting/application").
// Starts its own Stimulus application with the engine's controllers, independent of the host's.
import { Application } from "@hotwired/stimulus"
import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"

const application = Application.start()
eagerLoadControllersFrom("tudla_accounting/controllers", application)
