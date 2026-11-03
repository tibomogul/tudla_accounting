import { Controller } from "@hotwired/stimulus"
import { fieldUnits, parseUnits } from "tudla_accounting/amounts"

// On a payment started from an invoice, the cash starts at all that is owed, and comes down
// by the tax the customer withheld as it's typed, so the two together still settle the
// invoice. Once the cash has been changed by hand, it's left alone.
export default class extends Controller {
  static targets = ["cash", "withheld"]
  static values = { exponent: Number, started: Boolean }

  connect() {
    this.full = this.startedValue ? parseUnits(this.cashTarget.value, this.exponentValue) : null
  }

  cashTyped() {
    this.full = null
  }

  recalculate() {
    if (this.full === null) return

    const withheld = this.withheldTargets.reduce((sum, field) => sum + parseUnits(field.value, this.exponentValue), 0)
    this.cashTarget.value = fieldUnits(Math.max(this.full - withheld, 0), this.exponentValue)
  }
}
