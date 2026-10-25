// Reading and showing amounts in the browser, one way for every form's live totals, as
// the server reads them (TudlaAccounting::AmountParser): digits with "." for decimals,
// optionally grouped in thousands by commas, signed by "+", "-" or parentheses. Anything
// else counts as nothing here; the server says what is wrong with it.

const NUMBER = /^[+-]?(?:\d{1,3}(?:,\d{3})+|\d+)?(?:\.\d*)?$/

// A typed number, or null when blank or unreadable.
export function parseNumber(text) {
  let typed = String(text ?? "").trim()
  const negative = typed.startsWith("(") && typed.endsWith(")")
  if (negative) typed = typed.slice(1, -1).trim()
  if (!NUMBER.test(typed) || !/\d/.test(typed) || (negative && /^[+-]/.test(typed))) return null

  const number = Number(typed.replaceAll(",", ""))
  return negative ? -number : number
}

// A typed amount in minor units (cents), so totals don't pick up floating-point error;
// 0 when blank or unreadable.
export function parseUnits(text, exponent) {
  const number = parseNumber(text)
  return number === null ? 0 : Math.round(number * 10 ** exponent)
}

// Minor units as the page shows amounts, in the organization's style the layout gives
// (as tc_money writes them): "1,234.50", or "1.234,50" for books in euros.
export function formatUnits(units, exponent) {
  const { tcDecimalMark: decimalMark = ".", tcThousandsSeparator: separator = "," } = document.body.dataset
  const [whole, fraction] = (Math.abs(units) / 10 ** exponent).toFixed(exponent).split(".")
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, separator)
  return `${units < 0 ? "-" : ""}${grouped}${fraction ? decimalMark + fraction : ""}`
}

// Minor units as a form field holds them: "1234.50" (as tc_amount_field writes them).
export function fieldUnits(units, exponent) {
  return (units / 10 ** exponent).toFixed(exponent)
}
