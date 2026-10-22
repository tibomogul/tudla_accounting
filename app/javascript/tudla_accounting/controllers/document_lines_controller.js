import { Controller } from "@hotwired/stimulus"

// The invoice and bill form's lines: adds and removes them, works out each line's amount
// (quantity times unit price) and the subtotal, tax and total as they're typed, the way
// the server will (tax rounded per line, added or split out). Choosing a contact sets the
// due date from their payment terms (when the form has dates), and their default account and tax code on lines
// that have none yet. The server works it all out again.
export default class extends Controller {
  static targets = ["lines", "line", "template", "quantity", "price", "account", "tax", "amount", "destroy",
    "subtotal", "taxTotal", "total", "inclusive", "contact", "issued", "due"]
  static values = { exponent: { type: Number, default: 2 } }

  connect() {
    this.nextIndex = Date.now()
    this.recalculate()
  }

  add() {
    const html = this.templateTarget.innerHTML.replaceAll("NEW_LINE", String(this.nextIndex++))
    this.linesTarget.insertAdjacentHTML("beforeend", html)
    const line = this.lineTargets.at(-1)
    this.applyDefaults(line)
    line.querySelector("input[type=text]").focus()
    this.recalculate()
  }

  remove(event) {
    const line = event.target.closest("[data-document-lines-target=line]")
    if (line.querySelector("input[name$='[id]']")) {
      line.querySelector("[data-document-lines-target=destroy]").value = "1" // a saved line: the server removes it
      line.hidden = true
    } else {
      line.remove()
    }
    this.recalculate()
  }

  contactChanged() {
    const option = this.contactTarget.selectedOptions[0]
    if (!option || !option.value) return

    const terms = option.dataset.terms
    if (terms !== undefined && terms !== "" && this.hasIssuedTarget && this.issuedTarget.value) {
      const due = new Date(`${this.issuedTarget.value}T00:00:00Z`)
      due.setUTCDate(due.getUTCDate() + Number(terms))
      this.dueTarget.value = due.toISOString().slice(0, 10)
    }
    this.lineTargets.forEach((line) => this.applyDefaults(line))
    this.recalculate()
  }

  // The contact's default account and tax code, on a line that has no account yet.
  applyDefaults(line) {
    const option = this.hasContactTarget && this.contactTarget.selectedOptions[0]
    const account = line.querySelector("[data-document-lines-target=account]")
    if (!option || !option.value || account.value) return

    if (option.dataset.account) account.value = option.dataset.account
    const tax = line.querySelector("[data-document-lines-target=tax]")
    if (option.dataset.tax && !tax.value) tax.value = option.dataset.tax
  }

  recalculate() {
    const inclusive = this.hasInclusiveTarget && this.inclusiveTarget.checked
    let amounts = 0
    let taxes = 0
    this.lineTargets.filter((line) => !line.hidden).forEach((line) => {
      const quantity = Number(String(line.querySelector("[data-document-lines-target=quantity]").value).replaceAll(",", "").trim() || 1)
      const amount = Math.round((Number.isFinite(quantity) ? quantity : 0) * this.parse(line.querySelector("[data-document-lines-target=price]").value))
      const rate = Number(line.querySelector("[data-document-lines-target=tax]").selectedOptions[0]?.dataset.rate || 0)
      const tax = Math.round(inclusive ? amount * rate / (1 + rate) : amount * rate)
      line.querySelector("[data-document-lines-target=amount]").textContent = this.format(amount)
      amounts += amount
      taxes += tax
    })
    const subtotal = inclusive ? amounts - taxes : amounts
    this.subtotalTarget.textContent = this.format(subtotal)
    this.taxTotalTarget.textContent = this.format(taxes)
    this.totalTarget.textContent = this.format(subtotal + taxes)
  }

  // Amounts in minor units (cents), so totals don't pick up floating-point error.
  parse(text) {
    const number = Number(String(text).replaceAll(",", "").trim())
    return Number.isFinite(number) ? Math.round(number * 10 ** this.exponentValue) : 0
  }

  format(units) {
    return (units / 10 ** this.exponentValue).toLocaleString("en", { minimumFractionDigits: this.exponentValue, maximumFractionDigits: this.exponentValue })
  }
}
