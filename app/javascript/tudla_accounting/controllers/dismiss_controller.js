import { Controller } from "@hotwired/stimulus"

// Removes the element, e.g. a flash message's close button: data-action="dismiss#close"
export default class extends Controller {
  close() {
    this.element.remove()
  }
}
