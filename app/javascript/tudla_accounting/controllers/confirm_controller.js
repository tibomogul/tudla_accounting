import { Controller } from "@hotwired/stimulus"

// Asks before submitting a destructive form, inline rather than with a browser dialog:
// the first submit turns the button into "Click again to confirm".
export default class extends Controller {
  static values = { message: String }

  ask(event) {
    if (this.element.dataset.confirmed === "true") return

    event.preventDefault()
    this.element.dataset.confirmed = "true"
    const button = this.element.querySelector("[type=submit]")
    const label = `${this.messageValue} Click again to confirm`
    if (button.tagName === "INPUT") button.value = label // <input type=submit>: its label is its value
    else button.textContent = label
    button.setAttribute("aria-live", "polite")
  }
}
