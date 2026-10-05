import { Controller } from "@hotwired/stimulus"

// The entry form's lines: adds and removes lines, and keeps debit and credit totals
// with a balanced / unbalanced message as amounts are typed. The server checks again.
export default class extends Controller {
  static targets = ["lines", "line", "template", "debit", "credit", "destroy", "debitTotal", "creditTotal", "status"]
  static values = { exponent: { type: Number, default: 2 } }

  connect() {
    this.nextIndex = Date.now()
    this.recalculate()
  }

  add() {
    const html = this.templateTarget.innerHTML.replaceAll("NEW_LINE", String(this.nextIndex++))
    this.linesTarget.insertAdjacentHTML("beforeend", html)
    this.lineTargets.at(-1).querySelector("select").focus()
    this.recalculate()
  }

  remove(event) {
    const line = event.target.closest("[data-entry-lines-target=line]")
    const destroy = line.querySelector("[data-entry-lines-target=destroy]")
    if (line.querySelector("input[name$='[id]']")) {
      destroy.value = "1" // a saved line: keep it in the form so the server removes it
      line.hidden = true
    } else {
      line.remove()
    }
    this.recalculate()
  }

  recalculate() {
    const live = this.lineTargets.filter((line) => !line.hidden)
    const sum = (field) => live.reduce((total, line) => total + this.parse(line.querySelector(`[data-entry-lines-target=${field}]`).value), 0)
    const debit = sum("debit")
    const credit = sum("credit")

    this.debitTotalTarget.textContent = this.format(debit)
    this.creditTotalTarget.textContent = this.format(credit)

    const difference = debit - credit
    if (debit === 0 && credit === 0) {
      this.show("Enter the amounts for each line.", "tc-muted")
    } else if (difference === 0) {
      this.show(`Balanced: debits equal credits (${this.format(debit)}).`, "text-[var(--tc-success)]")
    } else {
      this.show(`Not balanced: ${difference > 0 ? "debits" : "credits"} are ${this.format(Math.abs(difference))} more.`, "text-[var(--tc-danger)]")
    }
  }

  // Amounts in minor units (cents), so totals don't pick up floating-point error.
  parse(text) {
    const number = Number(String(text).replaceAll(",", "").trim())
    return Number.isFinite(number) ? Math.round(number * 10 ** this.exponentValue) : 0
  }

  format(units) {
    return (units / 10 ** this.exponentValue).toLocaleString("en", { minimumFractionDigits: this.exponentValue, maximumFractionDigits: this.exponentValue })
  }

  show(message, className) {
    this.statusTarget.textContent = message
    this.statusTarget.className = `text-sm ${className}`
  }
}
