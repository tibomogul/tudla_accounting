import { Controller } from "@hotwired/stimulus"
import { fieldUnits, parseUnits } from "tudla_accounting/amounts"

// On a payment started from an invoice (or bill), the cash starts at all that is owed, and
// comes down by the tax withheld as it's typed, so the two together still settle it. Once
// the cash has been changed by hand, it's left alone. Paying a supplier, typing what the
// tax is withheld from (or choosing the code) works the tax out at the code's rate, and the
// cash is then that amount less the tax.
export default class extends Controller {
  static targets = ["cash", "withheld", "base"]
  static values = { exponent: Number, started: Boolean }

  connect() {
    this.full = this.startedValue ? parseUnits(this.cashTarget.value, this.exponentValue) + this.sum(this.withheldTargets) : null
  }

  cashTyped() {
    this.full = null
  }

  baseTyped(event) {
    const row = event.target.closest("tr")
    const base = row.querySelector("[data-withheld-cash-target='base']")
    const withheld = row.querySelector("[data-withheld-cash-target='withheld']")
    const rate = parseFloat(row.querySelector("select")?.selectedOptions[0]?.dataset.rate || "")
    if (!base || !withheld || Number.isNaN(rate) || base.value.trim() === "") return

    withheld.value = fieldUnits(Math.round(parseUnits(base.value, this.exponentValue) * rate), this.exponentValue)
    this.recalculate()
  }

  recalculate() {
    if (this.full === null) return

    const typedBases = this.baseTargets.filter((field) => field.value.trim() !== "")
    const full = typedBases.length > 0 ? this.sum(typedBases) : this.full
    this.cashTarget.value = fieldUnits(Math.max(full - this.sum(this.withheldTargets), 0), this.exponentValue)
  }

  sum(fields) {
    return fields.reduce((total, field) => total + parseUnits(field.value, this.exponentValue), 0)
  }
}
