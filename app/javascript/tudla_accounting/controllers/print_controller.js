import { Controller } from "@hotwired/stimulus"

// Opens the browser's print dialog, where the page can also be saved as a PDF (the
// engine's print styles leave out the navigation and forms): data-action="print#print"
export default class extends Controller {
  print() {
    window.print()
  }
}
