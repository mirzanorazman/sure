# Malaysian Statement Parser (kwgn port) — Design

Personal fork of `we-promise/sure`. Not intended for upstream.

## Problem

sure's PDF import (`PdfImport` + `ProcessPdfJob`) sends the whole statement to
an LLM (Anthropic/OpenAI) for classification and transaction extraction, and
then uploads it to the family vector store. The owner wants to import Malaysian
e-statements **without any LLM configured** and **without the statement ever
leaving the server** (no LLM, no embeddings API, no hosted vector store).

`kwgn-cli` (Go, regex + YAML config) already parses these statements reliably:
Maybank CASA/MAE, Maybank 2 credit card, Touch 'n Go eWallet.

## Decisions

| # | Decision |
|---|----------|
| Q1 | Personal fork only. Malaysia-specific code is fine; keep it behind a small parser interface. |
| Q2 | Drivers: privacy, and running with no LLM configured. |
| Q3 | E-statements (text PDFs) only. No OCR. |
| Q4 | Exactly three parsers: Maybank CASA/MAE, Maybank 2 credit card, Touch 'n Go. |
| Q5 | No account-number config. Detect statement type only; account comes from sure. |
| Q6 | Native Ruby port on `pdf-reader` (already in the Gemfile). No Go binary. |
| Q7 | Parsers only. An unrecognised PDF fails with "Unsupported statement format". No automatic LLM fallback. |
| Q8 | Parsed imports never upload to the vector store. |
| Q9 | After publish, run the family's active transaction rules. |
| Q10 | Check parsed rows against printed totals/balances; warn on mismatch, never block publish. |
| Q11 | Statements may be password-protected; the UI asks for the password. |
| Q12 | Each parser declares a fingerprint regex; the first matching parser runs. |
| Q13 | Parsing is synchronous inside the request. The password lives only in request memory — never persisted, never enqueued, never logged. |
| Q14 | The original PDF is stored as uploaded (still encrypted). No `qpdf`. |
| Q15 | Upstream AI path stays in the code, disabled unless `PDF_IMPORT_AI=true` (keeps rebases cheap). |
| Q16 | Transaction name = all description lines joined. Notes = reference only (when the statement has one). |
| Q17 | Tests use anonymised/synthetic *text* fixtures. Real PDFs stay out of git; an opt-in local test runs against them. |
| Q18 | Rules run against only the transactions this import created. |
| Q19 | Parsed account last-4 + institution feed `AccountStatement::AccountMatcher`; the suggestion pre-selects the account picker, user confirms. |
| Q20 | Closing balance is used for the totals check and to show the existing statement-vs-ledger reconciliation on the review screen. No balance entries are written. |
| Q21 | Password is asked only after the upload turns out to be encrypted; the stored (encrypted) upload is reused, no re-pick. |
| Q22 | One file per upload. |

## Non-goals

OCR, other banks, multi-file upload, upstream PR, writing valuation entries,
decrypting stored originals, changing the assistant's `import_bank_statement`
function (it is LLM-driven by definition).
