# Questions for an Australian tax adviser

Exported on 12 November 2026 from the [shared copy](https://claude.ai/artifact/98p28364LGT8SEMwv61Yd6), which is the one to send to an adviser and where their answers go. Copy the answers back here when they come in.

## How to use this

These are 23 questions about GST, the BAS, the TPAR and no-ABN withholding. We need an accountant or registered tax agent to confirm or correct them before the software's Australian reports are relied on.

**Priority:** questions 1–11 (tax invoices and the BAS) apply to our own business, so please answer those first. Questions 12–23 (the TPAR and no-ABN withholding) don't apply to us: we aren't in a TPAR industry and our suppliers quote ABNs. Other businesses using the software do need them, so answer them if you can, but they can wait.

The software is an accounting engine that keeps double-entry books and produces the figures for Australian reporting. It doesn't lodge anything: you copy the figures to the ATO's forms. Our understanding of the rules comes mostly from search summaries, because the ATO's website blocks automated reading. The only exception is three no-ABN pages, which were read in full.

Each table row gives:

- the question;
- what the software does now;
- what we'd change if the answer differs.

Please write your answer in the last column, or comment on the row. "Yes, that's right" is a useful answer. If an official page answers a question, a link is enough; the last section lists those pages.

**Already confirmed from the ATO's own pages, so no need to check:**

- the $75 no-ABN limit, judged before GST on the payment for the whole supply;
- the exceptions where nothing is withheld;
- that a supplier's statement is kept for 5 years and gives their name, address, reason and signature.

## Tax invoices and adjustment notes

The invoices print the seller's ABN, head themselves "Tax invoice", and show each line's GST treatment. These four points decide whether that meets GSTR 2013/1.

| # | Question | What the software does now | What we'd change if not | Answer |
| --- | --- | --- | --- | --- |
| 1 | Must a tax invoice carry the words "Tax invoice", or is it enough that it's intended as one? | Heads every approved sales invoice "Tax invoice" and a draft "Draft tax invoice". | Nothing if the words are optional; the setting can already change the title. |  |
| 2 | On an invoice with taxable and GST-free items, is it enough that each line names its GST treatment? | Each line shows its tax code ("GST (10%)"), the code's name for a zero-rate code ("GST-free"), or "No GST". | Add a line-by-line marker or a separate GST-free subtotal. |  |
| 3 | What must an adjustment note show? Does our credit note meet it? | A credit note shows the seller's ABN, the customer, the invoice it credits, each line with its GST, and the totals. It isn't titled "Adjustment note". | Add any missing field, and the title if it's required. |  |
| 4 | Which rounding rule applies, the total invoice rule or the taxable sale rule? | Works out GST on each line and rounds it there (half up by default), then adds the lines. | Round once on the invoice total, or per taxable sale, as you say. |  |

## BAS

The software has a BAS template that adds up the ledger by tax code and account into labels, which you copy to the activity statement. These questions check the template's mapping.

| # | Question | What the software does now | What we'd change if not | Answer |
| --- | --- | --- | --- | --- |
| 5 | Which labels should a template cover, and how are 8A and 8B worked out on a statement with both PAYG withholding and instalments? | Covers G1–G11, 1A, 1B, W1–W5, 5A, 5B, 8A, 8B and 9. It leaves out FBT, fuel tax credits, deferred instalments and the T labels. | Add the labels and correct the 8A and 8B formulas. |  |
| 6 | Is reporting G1 including GST right for most businesses, answering Yes to the form's question? | Reports G1 including GST, as the calculation worksheet method requires. The accounts method can report it without. | Default to excluding GST, or document when to switch. |  |
| 7 | Do exports at G2 and other GST-free sales at G3 also go into G1? | Includes both in G1. | Take them out of G1. |  |
| 8 | Should a purchase with no tax code count anywhere on the BAS? | Puts a purchase in G10 or G11 only through its tax code, so a purchase with no code reaches no label. | Count uncoded purchases in G11, or warn about them. |  |
| 9 | Are W2 (tax withheld from wages) and W4 (no-ABN withholding) the credits to their liability accounts in the period, before any payment to the ATO? | Adds the credits to each withholding account, less reversals. Payments to the ATO don't reduce them. W2's and W4's accounts are kept apart. | Change the basis. |  |
| 10 | Do 5A and 5B (PAYG instalments) come from the ATO's notice rather than the ledger? | Fills them from an account only if one is mapped; otherwise you type them when lodging. | Calculate them, if there's a ledger basis. |  |
| 11 | Can a business under $10 million turnover report only G1, 1A and 1B (Simpler BAS)? | Offers the full template. One secondary source says Simpler BAS applies. | Add a Simpler BAS template. |  |

## Taxable payments annual report (TPAR)

*Lower priority: doesn't apply to our own business, but other users of the software need it.*

You mark each contractor's contact as reported, and the software keeps that mark on every payment made to them. Its TPAR report lists what was paid to each marked payee over the financial year. It makes no file to lodge.

| # | Question | What the software does now | What we'd change if not | Answer |
| --- | --- | --- | --- | --- |
| 12 | Which businesses have to lodge? Is it those in building and construction, cleaning, couriers, road freight, IT, and security, investigation or surveillance? | Doesn't decide: you mark the contacts. The report appears once one is marked. | Only the documentation changes. |  |
| 13 | Are payments for materials only left out? Is a mixed payment reported in full unless the labour is incidental? | Counts every payment to a marked contact in full. A goods-only supplier is left unmarked, and a mixed payment is adjusted by hand. | Let a payment, or a bill line, be marked as not reportable. |  |
| 14 | What does the report have to contain, and in what file format? | Lists each payee's ABN, name, address and phone, the gross paid (including GST and any no-ABN tax), the GST, and the tax withheld. | Add any missing field, and the lodgment file. |  |
| 15 | Is the deadline 28 August after the financial year? | Doesn't state a deadline. | Show the due date on the report. |  |
| 16 | Is a refund from a contractor taken off in the month it's received? | Takes it off in that month, with the GST of the credit it repaid. A voided payment counts in the month it was voided. | Net it against the original payment's month instead. |  |

## No-ABN withholding

*Lower priority: doesn't apply to our own business, but other users of the software need it.*

When you pay a supplier who hasn't quoted an ABN, the software withholds tax at the code's rate. It keeps a reason on every such payment made without withholding, and lists each payee's year for the annual report, with a payment summary PDF for each.

| # | Question | What the software does now | What we'd change if not | Answer |
| --- | --- | --- | --- | --- |
| 17 | Is the rate still 47%? | The starter code is 47%, from the ATO's 2017 statement page; the newer page says "the top rate". The rate is yours to change. | Change the starter code. |  |
| 18 | How should the under-18 exception (an individual paid $350 or less a week) be handled? | Offers it as a reason on the supplier. It can't check age or weekly totals. | Add a weekly-total check, if that's the test. |  |
| 19 | How do we tell a supply split into small invoices from a series of separate small supplies? | Judges each bill on its own against the $75 limit. The README says to keep a split supply on one bill. | Group bills by supply, if there's a practical rule. |  |
| 20 | How should withholding from a non-cash payment be recorded? | Handles payments of money only. | Add a non-cash payment record. |  |
| 21 | If a supplier promises an ABN, may the payment be held back until it's quoted? Then paid in full? | Doesn't stop you paying in full: the payment keeps the reason you type, or "No reason given", flagged on the report. | Add a hold that's released when the ABN is entered. |  |
| 22 | Does our payment summary contain everything NAT 3283 asks for? What does the annual report (NAT 3448) contain, and in what format? | The summary has the payer and ABN, the payee's name and address, the months, gross payment and tax by code, each payment and void, and a blank line to sign. The report lists name, address, gross and tax. | Add any missing field, and the lodgment file. |  |
| 23 | When are payees given their summaries, and when is the annual report lodged? | States no dates. | Show the due dates. |  |

## Official pages that would answer some of these

These ATO publications would settle questions 1, 3, 11, 12, 14, 15, 17, 22 and 23 without an adviser. The ATO's site blocks automated reading, so a copy of the page text, or a PDF, is what's needed. These are names to search for on ato.gov.au, not links we've opened.

| Publication | Answers | What to look for |
| --- | --- | --- |
| GSTR 2013/1, Tax invoices | 1, 3 | Whether "Tax invoice" must appear; what an adjustment note must show |
| Simpler BAS | 11 | Who qualifies, and which labels are reported |
| Taxable payments annual report: who needs to lodge | 12 | The industries, and the payments that count |
| TPAR specification or instructions | 14, 15 | The fields, the file format, the due date |
| PAYG withholding: tax tables for no-ABN withholding | 17 | The current rate and its start date |
| PAYG payment summary – withholding where ABN not quoted (NAT 3283) | 22, 23 | Its content, and when payees get it |
| PAYG withholding where ABN not quoted – annual report (NAT 3448) | 22, 23 | Its fields, format and due date |

Already read, as copies supplied by the user:

- "Withholding if ABN is not provided" (ATO, last updated 11 June 2025);
- "Payments you don't withhold from" (11 June 2025);
- "Statement by a supplier not quoting an ABN" (30 June 2017).
