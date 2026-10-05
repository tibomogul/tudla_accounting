import { Controller } from "@hotwired/stimulus"

// Switches between light and dark. Saves the choice in localStorage("theme"), the key
// DaisyUI host apps use, so the engine and the host stay in step; until a choice is made
// the page follows the operating system's preference.
export default class extends Controller {
  static targets = ["sun", "moon"]

  connect() {
    this.media = window.matchMedia("(prefers-color-scheme: dark)")
    this.refresh = () => this.render()
    this.media.addEventListener("change", this.refresh)
    this.render()
  }

  disconnect() {
    this.media.removeEventListener("change", this.refresh)
  }

  toggle() {
    const theme = this.current() === "dark" ? "light" : "dark"
    document.documentElement.setAttribute("data-theme", theme)
    try { localStorage.setItem("theme", theme) } catch (_error) { /* storage unavailable: the switch lasts for this page */ }
    this.render()
  }

  current() {
    return document.documentElement.getAttribute("data-theme") || (this.media.matches ? "dark" : "light")
  }

  render() {
    const dark = this.current() === "dark"
    this.element.setAttribute("aria-label", dark ? "Switch to light theme" : "Switch to dark theme")
    this.element.setAttribute("aria-pressed", String(dark))
    // Offer the sun in dark mode and the moon in light. SVG elements have no `hidden`
    // property, so set the attribute.
    this.sunTarget.toggleAttribute("hidden", !dark)
    this.moonTarget.toggleAttribute("hidden", dark)
  }
}
