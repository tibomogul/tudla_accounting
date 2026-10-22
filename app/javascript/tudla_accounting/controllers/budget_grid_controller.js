import { Controller } from "@hotwired/stimulus"
import { parseUnits, formatUnits, fieldUnits } from "tudla_accounting/amounts"

// A budget's grid: keeps each account's year total, its parents' totals, each section's
// totals and the net profit up to date as amounts are typed, and spreads a year total
// typed in evenly over the months (what doesn't divide evenly going in the last month).
// The server works the totals out again.
export default class extends Controller {
  static targets = ["amount", "rowTotal", "sum", "sectionTotal", "net"]
  static values = { exponent: { type: Number, default: 2 } }

  connect() {
    this.recalculate()
  }

  recalculate() {
    const rows = {}
    const sums = {}
    const sections = {}
    const add = (totals, key, month, units) => {
      totals[key] ||= {}
      totals[key][month] = (totals[key][month] || 0) + units
      totals[key].year = (totals[key].year || 0) + units
    }
    this.amountTargets.forEach((input) => {
      const units = this.parse(input.value)
      const { account, month, category, ancestors, sign } = input.dataset
      rows[account] = (rows[account] || 0) + units
      ancestors.split(" ").filter(Boolean).forEach((ancestor) => add(sums, ancestor, month, units))
      add(sections, category, month, units * Number(sign))
    })

    this.rowTotalTargets.forEach((input) => {
      if (input !== document.activeElement) input.value = rows[input.dataset.account] ? this.plain(rows[input.dataset.account]) : ""
    })
    this.sumTargets.forEach((cell) => this.show(cell, sums[cell.dataset.account]?.[cell.dataset.month] || 0))
    this.sectionTotalTargets.forEach((cell) => this.show(cell, sections[cell.dataset.category]?.[cell.dataset.month] || 0))
    this.netTargets.forEach((cell) => {
      const month = cell.dataset.month
      this.show(cell, (sections.income?.[month] || 0) - (sections.expense?.[month] || 0))
    })
  }

  spread(event) {
    const total = this.parse(event.target.value)
    const inputs = this.amountTargets.filter((input) => input.dataset.account === event.target.dataset.account)
    const each = Math.trunc(total / inputs.length)
    inputs.forEach((input, index) => {
      const units = index === inputs.length - 1 ? total - each * (inputs.length - 1) : each
      input.value = units ? this.plain(units) : ""
    })
    this.recalculate()
  }



  // An amount as the page shows amounts: separators, negatives in parentheses.
  show(cell, units) {
    const text = this.format(Math.abs(units))
    cell.innerHTML = ""
    if (units < 0) {
      const span = document.createElement("span")
      span.className = "tc-negative"
      span.textContent = `(${text})`
      cell.append(span)
    } else {
      cell.textContent = text
    }
  }

  // Amounts in the currency's minor units (see tudla_accounting/amounts).
  parse(text) { return parseUnits(text, this.exponentValue) }
  format(units) { return formatUnits(units, this.exponentValue) }
  plain(units) { return fieldUnits(units, this.exponentValue) }
}
