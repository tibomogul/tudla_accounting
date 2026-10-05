import { Controller } from "@hotwired/stimulus"

// Opening balances: totals the debit-side and credit-side amounts as they are typed and
// says whether they balance. The server checks again before saving.
export default class extends Controller {
  static targets = ["amount", "debitTotal", "creditTotal", "status"]
  static values = { exponent: { type: Number, default: 2 } }

  connect() {
    this.recalculate()
  }

  recalculate() {
    const total = (side) => this.amountTargets
      .filter((input) => input.dataset.side === side)
      .reduce((sum, input) => sum + this.parse(input.value), 0)
    const debit = total("debit")
    const credit = total("credit")

    this.debitTotalTarget.textContent = this.format(debit)
    this.creditTotalTarget.textContent = this.format(credit)
    if (debit === credit) {
      this.show("Balanced.", "text-[var(--tc-success)]")
    } else {
      this.show(`Not balanced: ${debit > credit ? "debits" : "credits"} are ${this.format(Math.abs(debit - credit))} more.`, "text-[var(--tc-danger)]")
    }
  }

  parse(text) {
    const number = Number(String(text).replaceAll(",", "").trim())
    return Number.isFinite(number) ? Math.round(number * 10 ** this.exponentValue) : 0
  }

  format(units) {
    return (units / 10 ** this.exponentValue).toLocaleString("en", { minimumFractionDigits: this.exponentValue, maximumFractionDigits: this.exponentValue })
  }

  show(message, className) {
    this.statusTarget.textContent = message
    this.statusTarget.className = `text-sm mt-1 ${className}`
  }
}
