# Questions for a Philippine tax adviser

Exported on 12 November 2026 from the [shared copy](https://claude.ai/artifact/FQzL3LubmMHLY3tFBLPBdd), which is the one to send to an adviser and where their answers go. Copy the answers back here when they come in.

## How to use this

These are 14 questions about expanded withholding, Form 2307, the QAP, SAWT and SLSP, Form 2550Q and the books of accounts. We need an accountant, or the company's RDO, to confirm or correct them before the software's Philippine outputs are filed.

The software is an accounting engine that keeps double-entry books for a VAT-registered company. It produces the figures, lists and a rebuilt Form 2307, but files nothing. It makes no DAT files, so lists are re-keyed or imported by hand. Our understanding comes from BIR digests and forms where we could open them, and otherwise from secondary commentary, because several BIR copies couldn't be fetched.

Each table row gives:

- the question;
- what the software does now;
- what we'd change if the answer differs.

Please write your answer in the last column, or comment on the row. "Yes, that's right" is a useful answer. If an issuance answers a question, its number is enough; the last section lists those.

**Already taken from BIR sources:**

- the top withholding agents' rates of 1% on goods and 2% on services from 10 October 2025 (the BIR's digest of RR 24-2025);
- the 5% and 10% rates for individual professionals (the digest of RR 11-2018);
- the layout of Form 2307's January 2018 edition.

## Expanded withholding

A bill line can carry an ATC; approving the bill posts the tax withheld and lowers what's owed to the supplier. A payment received can record the tax a customer withheld, as their 2307 gives it.

| # | Question | What the software does now | What we'd change if not | Answer |
| --- | --- | --- | --- | --- |
| 1 | Is the expanded withholding tax worked out on the amount before VAT? | Works it out on each bill line's amount before VAT. Most commentary agrees; one source we read disagrees. | Work it out on the gross, or make it a setting. |  |
| 2 | Are the starter codes and rates current? | Offers 20 ATCs from Form 1601-EQ (January 2019) and RR 24-2025, such as WC010 10%, WC120 2%, WC158 1% and WC160 2%. It leaves out the 0.5% codes in RMC 36-2026. | Correct the rates, and add or drop codes. |  |
| 3 | Does the duty to withhold arise when the income becomes payable, so when the bill is approved? | Posts the tax when the bill is approved, not when it's paid. | Post it on payment instead, as it does for Australia's no-ABN tax. |  |
| 4 | Should the SAWT list only amounts whose 2307 has been received? | Lists only amounts marked as received, and shows the unmarked total beside them. | List every amount, flagging those with no certificate. |  |

## BIR Form 2307

The software prints a 2307 for each supplier and quarter, on 8.5 x 13 inch paper. It follows the first page of the January 2018 edition, without the seal and barcode: income by ATC and month, the quarter's tax, and the company's details. Signatures are left blank.

| # | Question | What the software does now | What we'd change if not | Answer |
| --- | --- | --- | --- | --- |
| 5 | Will the BIR, and the supplier's RDO, accept a 2307 rebuilt by software rather than the BIR's own form? | Prints the rebuilt form, and the README says to check before issuing it. | Fill the BIR's PDF instead, if only that is accepted. |  |
| 6 | When must the 2307 be given to the supplier? Is it by the 20th day after the quarter? | States no deadline. | Show the due date on the certificates page. |  |
| 7 | For an individual supplier, must the name be split into last, first and middle names? | Prints the contact's single name field as it is. Names and addresses stop at two lines. | Add separate name fields for individuals. |  |

## QAP, SAWT and the summary lists (SLSP)

The software lists these on screen and in Excel and CSV, by quarter by default. It makes no DAT file, because we haven't found the record layouts.

| # | Question | What the software does now | What we'd change if not | Answer |
| --- | --- | --- | --- | --- |
| 8 | What columns do the QAP and SAWT need, in what order? | The QAP has payee TIN, name, ATC, income, rate and tax; the SAWT has the withholding agent's TIN, name, ATC, income and tax. A contact with no TIN is flagged. | Match the BIR's specification. |  |
| 9 | What fields and column order does the SLSP need under RR 1-2012? | Sales: exempt, zero-rated and VATable, with output tax. Purchases: exempt, zero-rated, services, capital goods and other goods, with input tax and the seller's address. Fields are from RR 16-2005, written when VAT was 10%. | Match RR 1-2012, and any change in RMC 98-2026 (named by one site, unread). |  |
| 10 | Can these still be filed as Excel, or only as validated DAT files? Where are the DAT record layouts published? | Makes Excel and CSV only. | Build the DAT files from the layouts (the annexes to RMC 24-2002, or the BIR's RELIEF job aid). |  |
| 11 | Does the SLSP count by invoice or posting month? Is a line with no tax code exempt? Is the old split of regular and casual buyers still needed? | Lists by posting month, as the VAT return does on the accrual basis. Counts an uncoded line as exempt and flags the amount. Lists every buyer, with no regular or casual split. | Change the month basis, the uncoded treatment, or add the split. |  |

## Form 2550Q and the books of accounts

The software has a 2550Q template that adds up the ledger by tax code into the return's items, which you copy across. It prints six loose-leaf books, as PDF and Excel, for binding.

| # | Question | What the software does now | What we'd change if not | Answer |
| --- | --- | --- | --- | --- |
| 12 | Where do capital goods of ₱1 million or less go on the 2550Q? Is deferred input tax on larger ones (items 39B and 52B) still worked out? Are the item numbers current? | Puts the smaller ones on item 44A with domestic purchases, our reading of the layout. Works out no deferred input tax. | Move them, add the deferral, or renumber. |  |
| 13 | Will the RDO accept these loose-leaf books as laid out? What does it need to see before approving the format? | The six books are the general journal, general ledger, cash receipts, cash disbursements, sales and purchase journals. Pages are 30 rows, numbered, with totals and a check. A sample format with made-up rows prints for the application, and a cover sheet counts the pages for the sworn statement. | Change columns or layout to the format the RDO wants. |  |
| 14 | Are the journals' columns right? | Columns are receivable or payable, sales or expenses, and output or input VAT. The sales journal adds VATable, zero-rated, exempt and the customer's TIN. Anything else goes under Other accounts. An entry goes in one book only, cash receipts and disbursements taking priority. | Add or change columns, or the book an entry goes in. |  |

## Issuances that would answer some of these

These BIR documents would settle questions 2, 6 and 8 to 12 without an adviser. A copy or PDF is what's needed, because the BIR's own copies often wouldn't load for us. They're names to search for, not links we've opened.

| Issuance | Answers | What to look for |
| --- | --- | --- |
| RR 1-2012 (full text) | 9, 11 | The SLSP's fields, and when lists are filed |
| RMC 98-2026 | 9, 10 | Whatever it changes on the summary lists |
| RMC 24-2002 annexes, or the BIR's RELIEF job aid | 10 | The DAT record layout for the SLSP |
| The BIR's alphalist data entry job aid, or its specification | 8, 10 | The QAP and SAWT columns and DAT layout |
| The current ATC list for Form 1601-EQ | 2 | Codes and rates after RR 24-2025 |
| The rule on issuing Form 2307 | 6 | When the certificate is due to the payee |
| The current Form 2550Q and its guidelines | 12 | Where capital goods go, and the item numbers |

Already read:

- [BIR digest of RR 24-2025](https://bir-cdn.bir.gov.ph/BIR/pdf/RR%20No.%2024-2025%20Digest%20FINAL.pdf), top withholding agents' rates;
- [BIR digest of RR 11-2018](https://bir-cdn.bir.gov.ph/local/pdf/Digest%20RR%2011-2018.pdf), professionals' rates;
- [Form 1601-EQ, January 2019](https://www.grantthornton.com.ph/contentassets/414c853f9bc7464c90825a99932f5086/annex-a-1601-eq-january-2019-encs.pdf), the ATCs;
- [RMC 74-2019](https://www.grantthornton.com.ph/globalassets/1.-member-firms/philippines/tax-alerts/2019/07.29.2019/rmc-no.-74-2019.pdf), which announced the January 2018 Form 2307;
- [RMC 36-2026 summary](https://www.divinalaw.com/wp-content/uploads/2026/05/BIR-08-BIR-RMC-No.-36-2026.pdf), the 0.5% codes;
- [RMC 79-2026 clarifications](https://www.roxastabamo.com/clarifying-the-provisions-of-revenue-regulations-rr-no-024-2025/) (Moore Roxas Tabamo), on RR 24-2025;
- the January 2018 Form 2307 (bir-cdn.bir.gov.ph);
- an unofficial copy of RR 16-2005, §4.114-3, the SLSP fields.
