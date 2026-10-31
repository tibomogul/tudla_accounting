// Reading and showing amounts in the browser, one way for every form's live totals, as
// the server reads them (TudlaAccounting::AmountParser) in the organization's number
// format, which the layout gives: digits with its decimal mark ("." or ","), optionally
// grouped in thousands by its separator, signed by "+", "-" or parentheses. Anything else
// counts as nothing here; the server says what is wrong with it.

function marks() {
  const { tcDecimalMark: decimal = ".", tcThousandsSeparator: thousands = "," } = document.body.dataset
  return { decimal, thousands }
}

const escape = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")

function pattern({ decimal, thousands }) {
  const grouped = thousands ? `\\d{1,3}(?:${escape(thousands)}\\d{3})+|` : ""
  return new RegExp(`^[+-]?(?:${grouped}\\d+)?(?:${escape(decimal)}\\d*)?$`)
}

// A typed number, or null when blank or unreadable.
export function parseNumber(text) {
  const { decimal, thousands } = marks()
  let typed = String(text ?? "").trim()
  const negative = typed.startsWith("(") && typed.endsWith(")")
  if (negative) typed = typed.slice(1, -1).trim()
  if (!pattern({ decimal, thousands }).test(typed) || !/\d/.test(typed) || (negative && /^[+-]/.test(typed))) return null

  const plain = (thousands ? typed.replaceAll(thousands, "") : typed).replace(decimal, ".")
  const number = Number(plain)
  return negative ? -number : number
}

// A typed amount in minor units (cents), so totals don't pick up floating-point error;
// 0 when blank or unreadable.
export function parseUnits(text, exponent) {
  const number = parseNumber(text)
  return number === null ? 0 : Math.round(number * 10 ** exponent)
}

// Minor units as the page shows amounts, in the organization's style the layout gives
// (as tc_money writes them): "1,234.50", or "1.234,50" in comma books.
export function formatUnits(units, exponent) {
  const { decimal, thousands } = marks()
  const [whole, fraction] = (Math.abs(units) / 10 ** exponent).toFixed(exponent).split(".")
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, thousands)
  return `${units < 0 ? "-" : ""}${grouped}${fraction ? decimal + fraction : ""}`
}

// Minor units as a form field holds them: "1234.50", or "1234,50" in comma books (as
// tc_amount_field writes them).
export function fieldUnits(units, exponent) {
  return (units / 10 ** exponent).toFixed(exponent).replace(".", marks().decimal)
}
