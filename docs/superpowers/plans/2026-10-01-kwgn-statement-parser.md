# Malaysian Statement Parser (kwgn port) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import Maybank CASA/MAE, Maybank 2 credit card and Touch 'n Go e-statement PDFs into sure with deterministic regex parsers, so no statement content ever reaches an LLM, embeddings API or vector store.

**Architecture:** A new `StatementParser` module (`app/models/statement_parser/`) turns PDF bytes into a `StatementParser::Result` (transactions + printed totals/balances). The upload action in `ImportsController` parses synchronously, then hands the result to `PdfImport`, which reuses its existing row generation, reconciliation, review and publish pipeline. `ProcessPdfJob` and the AI path are untouched but only reachable when `PDF_IMPORT_AI=true`.

**Tech Stack:** Rails 7 / Ruby 3.4, `pdf-reader` 2.15.1 (already bundled; supports RC4, AES-128 and AES-256 decryption), Minitest + Mocha, Hotwire/ERB views.

**Spec:** `docs/superpowers/specs/2026-10-01-kwgn-statement-parser-design.md`

**Porting source (read-only reference):** `../kwgn-cli/extractor/{mbb_mae_and_casa,mbb_2_cc,tng}/` and the `statement:` block of `../kwgn-ui/.kwgn.yaml`. Do **not** copy anything from the `accounts:` block of that file or the card numbers in `kwgn-cli/extractor/mbb_2_cc/handler_test.go` — they are the owner's real account numbers.

## Global Constraints

- The PDF password is never persisted (DB, Active Storage metadata, cache), never passed to a job, never logged, never included in an exception message or `cause`. `pdf-reader` raises `EncryptedPDFError, "Invalid password (#{pass})"` — that message must not escape `StatementParser::TextExtractor`.
- The parser path never calls `ProcessPdfJob`, `PdfImport#process_with_ai`, `#extract_transactions`, `Family#upload_document`, or any `Provider::*`/`VectorStore::*` code.
- The upstream AI path is enabled only when `ENV["PDF_IMPORT_AI"]` casts to true (`ActiveModel::Type::Boolean`). Default: off.
- Amount sign in `StatementParser::Transaction#amount` and in `extracted_data["transactions"][]["amount"]`: **inflows positive** (deposit/refund/payment-to-card > 0, spend < 0). This matches `PdfImport`'s default `signage_convention: "inflows_positive"`.
- Currency for all three parsers: `"MYR"`.
- No real statement PDFs, account numbers or card numbers in git. Fixtures are synthetic or anonymised text.
- Keep changes to upstream files minimal and additive (the fork is rebased onto the `upstream` remote, `we-promise/sure`). New behaviour lives in new files.
- Locale strings: add English keys to `config/locales/views/imports/en.yml` only; `test/i18n_test.rb` must stay green.
- Before each commit: `bin/rubocop -a <changed files>` and, for ERB, `bundle exec erb_lint <changed erb> -a`.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Password leakage via exception cause/message** — a wrong password must surface as `StatementParser::WrongPassword` with a fixed message and `cause == nil`, and the controller must never flash or log it. Test pinned in Task 1.
2. **A layout drift silently drops rows** — the parser must still return a result, and the review screen must show a totals mismatch warning rather than a clean import. Tests pinned in Task 2 (checks) and Task 9 (warning rendered).
3. **Credit-card rows crossing the year boundary** (a December line on a January statement) must land in the previous year. Test pinned in Task 4.
4. **Failed Touch 'n Go transactions** must not be imported as money movements. Test pinned in Task 5.
5. **Re-uploading a statement already imported** (duplicate checksum) must reuse the existing import and not re-parse or duplicate rows. Test pinned in Task 7.

---

## File Structure

**Create**
- `app/models/statement_parser.rb` — module: error classes, `parsers`, `parse(content, password:)`.
- `app/models/statement_parser/text_extractor.rb` — PDF bytes (+password) → array of text lines; maps pdf-reader errors to parser errors.
- `app/models/statement_parser/transaction.rb` — `Data` value object (date, amount, name, notes).
- `app/models/statement_parser/result.rb` — `Data` value object + totals/balance `checks`.
- `app/models/statement_parser/base.rb` — shared helpers (money, year inference, fingerprint match).
- `app/models/statement_parser/maybank_casa.rb`
- `app/models/statement_parser/maybank_credit_card.rb`
- `app/models/statement_parser/touch_n_go.rb`
- `app/models/pdf_import/statement_parsing.rb` — concern included in `PdfImport`: apply a result, password-required state, discard, rules after publish.
- `app/controllers/import/pdf_passwords_controller.rb`
- `app/views/imports/_pdf_password_form.html.erb`
- `app/views/imports/_pdf_statement_checks.html.erb`
- `lib/tasks/statement_parser.rake` — `statement_parser:dump[path]` prints extracted lines for fixture writing.
- `test/fixtures/files/statement_parser/{maybank_casa,maybank_credit_card,touch_n_go}.txt`
- `test/fixtures/files/imports/sample_bank_statement_encrypted.pdf` (generated once with qpdf)
- `test/models/statement_parser/*_test.rb`, `test/models/pdf_import_statement_parsing_test.rb`, `test/controllers/import/pdf_passwords_controller_test.rb`

**Modify**
- `app/models/pdf_import.rb` — include concern; `create_from_prepared_upload!`; `configured?` uses `processed?`; call rules hook at end of `import!`.
- `app/models/rule.rb` — optional `transaction_ids:` narrowing on `apply`.
- `app/controllers/imports_controller.rb` — `create_pdf_import` parses first; PDF option offered without a vector store; PDFs never routed through the vector-store path.
- `app/views/imports/_pdf_import.html.erb` — password branch, checks partial, pre-selected suggested account.
- `config/routes.rb` — `resource :pdf_password`.
- `config/locales/views/imports/en.yml`
- `test/controllers/imports_controller_test.rb` — existing AI-path PDF tests now opt in via `PdfImport.stubs(:ai_processing_enabled?)`.

---

### Task 0: Branch

- [ ] **Step 1: Create the working branch from the current checkout**

```bash
cd /Users/mirzahaikarl/Developer/Projects/sure
git switch -c kwgn-parser
```

Expected: `Switched to a new branch 'kwgn-parser'`. (Local `main` is upstream's v0.7.4 release commit; the branch starts there.)

- [ ] **Step 2: Commit the spec and this plan**

```bash
git add docs/superpowers/specs/2026-10-01-kwgn-statement-parser-design.md docs/superpowers/plans/2026-10-01-kwgn-statement-parser.md
git commit -m "docs: plan Malaysian statement parser (kwgn port)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 1: Text extraction with password handling (+ dump tool)

This task also de-risks the plan: Step 7 runs the dump against a real Maybank PDF. If pdf-reader cannot open it, **stop and report** — the fallback (adding `qpdf` to the image) is a spec change.

**Files:**
- Create: `app/models/statement_parser.rb`, `app/models/statement_parser/text_extractor.rb`, `lib/tasks/statement_parser.rake`
- Create: `test/fixtures/files/imports/sample_bank_statement_encrypted.pdf`
- Test: `test/models/statement_parser/text_extractor_test.rb`

**Interfaces:**
- Produces: `StatementParser::Error < StandardError`; subclasses `PasswordRequired`, `WrongPassword`, `Unsupported`, `Unreadable`.
- Produces: `StatementParser::TextExtractor.lines(content, password: nil) -> Array<String>` (right-stripped, blank lines removed).

- [ ] **Step 1: Generate the encrypted fixture (one-off, local)**

```bash
brew install qpdf
qpdf --encrypt test1234 owner1234 256 -- \
  test/fixtures/files/imports/sample_bank_statement.pdf \
  test/fixtures/files/imports/sample_bank_statement_encrypted.pdf
```

Expected: file created. `qpdf --show-encryption test/fixtures/files/imports/sample_bank_statement_encrypted.pdf --password=test1234` reports `R = 6` (AES-256).

- [ ] **Step 2: Write the failing test**

`test/models/statement_parser/text_extractor_test.rb`:

```ruby
require "test_helper"

class StatementParser::TextExtractorTest < ActiveSupport::TestCase
  setup do
    @plain = file_fixture("imports/sample_bank_statement.pdf").binread
    @encrypted = file_fixture("imports/sample_bank_statement_encrypted.pdf").binread
  end

  test "extracts non-blank, right-stripped lines" do
    lines = StatementParser::TextExtractor.lines(@plain)

    assert lines.any?
    assert lines.none?(&:blank?)
    assert lines.none? { |line| line.end_with?(" ") }
  end

  test "asks for a password when the PDF is protected" do
    assert_raises(StatementParser::PasswordRequired) do
      StatementParser::TextExtractor.lines(@encrypted)
    end
  end

  test "rejects a wrong password without echoing it" do
    error = assert_raises(StatementParser::WrongPassword) do
      StatementParser::TextExtractor.lines(@encrypted, password: "hunter2-secret")
    end

    assert_not_includes error.message, "hunter2-secret"
    assert_nil error.cause
  end

  test "decrypts with the right password" do
    assert_equal StatementParser::TextExtractor.lines(@plain),
                 StatementParser::TextExtractor.lines(@encrypted, password: "test1234")
  end

  test "reports content that is not a readable PDF" do
    assert_raises(StatementParser::Unreadable) do
      StatementParser::TextExtractor.lines("%PDF-1.4\nnot really a pdf")
    end
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bin/rails test test/models/statement_parser/text_extractor_test.rb`
Expected: FAIL/ERROR with `uninitialized constant StatementParser`.

- [ ] **Step 4: Implement**

`app/models/statement_parser.rb`:

```ruby
# Deterministic parsers for Malaysian e-statements (ported from kwgn). Nothing
# here talks to an LLM, an embeddings API or a vector store: the statement is
# read with pdf-reader and matched with regular expressions, in-process.
module StatementParser
  class Error < StandardError; end
  class PasswordRequired < Error; end
  class WrongPassword < Error; end
  class Unsupported < Error; end
  class Unreadable < Error; end
end
```

`app/models/statement_parser/text_extractor.rb`:

```ruby
class StatementParser::TextExtractor
  # pdf-reader's layout text keeps column spacing, which the parsers rely on to
  # tell a description continuation line from a new row.
  def self.lines(content, password: nil)
    reader = PDF::Reader.new(StringIO.new(content), password: password.presence)
    reader.pages.flat_map { |page| page.text.lines }.map(&:rstrip).reject(&:blank?)
  rescue PDF::Reader::EncryptedPDFError
    # pdf-reader's message is "Invalid password (<the password>)". Raise a fresh
    # error with no cause so the password cannot reach logs or Sentry.
    error = password.present? ? StatementParser::WrongPassword : StatementParser::PasswordRequired
    raise error, cause: nil
  rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError
    raise StatementParser::Unreadable, cause: nil
  end
end
```

`lib/tasks/statement_parser.rake`:

```ruby
namespace :statement_parser do
  desc "Print the text lines the statement parsers see for a PDF (for writing fixtures). Prompts for a password if needed."
  task :dump, [ :path ] => :environment do |_task, args|
    require "io/console"

    content = File.binread(args.fetch(:path))
    lines =
      begin
        StatementParser::TextExtractor.lines(content)
      rescue StatementParser::PasswordRequired
        StatementParser::TextExtractor.lines(content, password: $stdin.getpass("PDF password: "))
      end

    puts lines
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/models/statement_parser/text_extractor_test.rb`
Expected: 5 runs, 0 failures. If "reports content that is not a readable PDF" fails because pdf-reader raises a different class, add that class to the `Unreadable` rescue (check the actual class in the failure output) — do not rescue `StandardError`.

- [ ] **Step 6: Commit**

```bash
git add app/models/statement_parser.rb app/models/statement_parser/text_extractor.rb lib/tasks/statement_parser.rake test/models/statement_parser/text_extractor_test.rb test/fixtures/files/imports/sample_bank_statement_encrypted.pdf
git commit -m "feat(statement-parser): extract PDF text lines with password handling

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 7: Real-PDF gate (needs the owner)**

Ask the owner to copy one statement of each kind (CASA/MAE, Maybank 2 card, TNG) into a folder **outside the repo**, e.g. `~/statements/`, then run for each:

```bash
bin/rails "statement_parser:dump[$HOME/statements/<file>.pdf]" > ~/statements/<file>.txt
```

Expected: readable lines for all three, including any password-protected one. Record in the task report: (a) whether each file was encrypted and opened, (b) the exact line shapes for header/account number, balance lines, a transaction line, a continuation line, totals. Keep these `.txt` files out of the repo; Tasks 3–5 use them to confirm the synthetic fixtures match reality (Task 11 re-checks everything).

---

### Task 2: Result and Transaction value objects with totals checks

**Files:**
- Create: `app/models/statement_parser/transaction.rb`, `app/models/statement_parser/result.rb`
- Test: `test/models/statement_parser/result_test.rb`

**Interfaces:**
- Produces: `StatementParser::Transaction.new(date: Date, amount: BigDecimal, name: String, notes: String|nil)` — amount inflows positive.
- Produces: `StatementParser::Result.new(parser_key:, document_type:, institution_name:, account_last4:, currency:, liability:, period_start_on:, period_end_on:, opening_balance:, closing_balance:, printed_total_credit:, printed_total_debit:, transactions:)` with `#inflow_total`, `#outflow_total`, `#net_movement` (BigDecimal) and `#checks -> Array<Hash{"key","printed","parsed","matched"}>` (string keys; amounts as `"F"`-format strings).

- [ ] **Step 1: Write the failing test**

`test/models/statement_parser/result_test.rb`:

```ruby
require "test_helper"

class StatementParser::ResultTest < ActiveSupport::TestCase
  def txn(amount)
    StatementParser::Transaction.new(date: Date.new(2025, 1, 2), amount: BigDecimal(amount), name: "x", notes: nil)
  end

  def result(**overrides)
    StatementParser::Result.new(**{
      parser_key: "test", document_type: "bank_statement", institution_name: "Maybank",
      account_last4: "9012", currency: "MYR", liability: false,
      period_start_on: Date.new(2025, 1, 1), period_end_on: Date.new(2025, 1, 31),
      opening_balance: BigDecimal("1000"), closing_balance: BigDecimal("3349.50"),
      printed_total_credit: BigDecimal("2500"), printed_total_debit: BigDecimal("150.50"),
      transactions: [ txn("-150"), txn("2500"), txn("-0.50") ]
    }.merge(overrides))
  end

  test "totals split inflows and outflows" do
    r = result
    assert_equal BigDecimal("2500"), r.inflow_total
    assert_equal BigDecimal("150.50"), r.outflow_total
    assert_equal BigDecimal("2349.50"), r.net_movement
  end

  test "all checks match for a consistent deposit statement" do
    checks = result.checks
    assert_equal %w[total_credit total_debit closing_balance], checks.map { _1["key"] }
    assert checks.all? { _1["matched"] }
  end

  test "a dropped row shows up as mismatched checks" do
    checks = result(transactions: [ txn("-150"), txn("2500") ]).checks.index_by { _1["key"] }

    assert checks["total_credit"]["matched"]
    assert_not checks["total_debit"]["matched"]
    assert_equal "150.5", checks["total_debit"]["printed"]
    assert_equal "150.0", checks["total_debit"]["parsed"]
    assert_not checks["closing_balance"]["matched"]
  end

  test "liability balances move opposite to cash" do
    card = result(
      liability: true,
      opening_balance: BigDecimal("1200"), closing_balance: BigDecimal("109.30"),
      printed_total_credit: BigDecimal("1200"), printed_total_debit: BigDecimal("109.30"),
      transactions: [ txn("-85.90"), txn("1200"), txn("-23.40") ]
    )
    assert card.checks.all? { _1["matched"] }
  end

  test "no printed figures means no checks" do
    r = result(opening_balance: nil, closing_balance: nil, printed_total_credit: nil, printed_total_debit: nil)
    assert_empty r.checks
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/models/statement_parser/result_test.rb`
Expected: ERROR `uninitialized constant StatementParser::Transaction`.

- [ ] **Step 3: Implement**

`app/models/statement_parser/transaction.rb`:

```ruby
# amount is inflows-positive: money in (deposit, refund, card payment) > 0.
StatementParser::Transaction = Data.define(:date, :amount, :name, :notes)
```

`app/models/statement_parser/result.rb`:

```ruby
StatementParser::Result = Data.define(
  :parser_key, :document_type, :institution_name, :account_last4, :currency, :liability,
  :period_start_on, :period_end_on, :opening_balance, :closing_balance,
  :printed_total_credit, :printed_total_debit, :transactions
) do
  def inflow_total
    transactions.sum(BigDecimal("0")) { |txn| txn.amount.positive? ? txn.amount : 0 }
  end

  def outflow_total
    transactions.sum(BigDecimal("0")) { |txn| txn.amount.negative? ? -txn.amount : 0 }
  end

  def net_movement
    inflow_total - outflow_total
  end

  # The bank's "credit" is money in on both a deposit account and a card (a
  # payment or refund), so printed credits compare with inflows either way.
  # Only the running balance flips: paying a card down reduces what is owed.
  def checks
    list = []
    list << check("total_credit", printed_total_credit, inflow_total) if printed_total_credit
    list << check("total_debit", printed_total_debit, outflow_total) if printed_total_debit
    if opening_balance && closing_balance
      expected = liability ? opening_balance - net_movement : opening_balance + net_movement
      list << check("closing_balance", closing_balance, expected)
    end
    list
  end

  private
    def check(key, printed, parsed)
      {
        "key" => key,
        "printed" => printed.to_d.to_s("F"),
        "parsed" => parsed.to_d.to_s("F"),
        "matched" => (printed.to_d - parsed.to_d).abs <= BigDecimal("0.01")
      }
    end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/models/statement_parser/result_test.rb`
Expected: 5 runs, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/models/statement_parser/transaction.rb app/models/statement_parser/result.rb test/models/statement_parser/result_test.rb
git commit -m "feat(statement-parser): result value object with totals and balance checks

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Shared base + Maybank CASA/MAE parser

Port of `kwgn-cli/extractor/mbb_mae_and_casa/handler.go`. Differences from kwgn, on purpose: `\s+` instead of a single space between amount and balance (pdf-reader keeps column spacing); a continuation line must be indented to at least the description column and must not be a balance/total/header line (kwgn attached any indented line, including page furniture); lines that are only punctuation (e.g. `*`) are dropped from the name.

**Files:**
- Create: `app/models/statement_parser/base.rb`, `app/models/statement_parser/maybank_casa.rb`
- Create: `test/fixtures/files/statement_parser/maybank_casa.txt`
- Test: `test/models/statement_parser/maybank_casa_test.rb`

**Interfaces:**
- Consumes: `StatementParser::Result`, `StatementParser::Transaction`, `StatementParser::Unsupported` (Tasks 1–2).
- Produces: `StatementParser::Base.matches?(lines) -> bool` (uses the subclass's `FINGERPRINT`); `#initialize(lines)`; `#parse -> StatementParser::Result`.
- Produces: `StatementParser::MaybankCasa` with `parser_key "maybank_casa"`, `document_type "bank_statement"`, `institution_name "Maybank"`, `liability false`.

- [ ] **Step 1: Write the fixture**

`test/fixtures/files/statement_parser/maybank_casa.txt` (synthetic; account number is fake). Compare its shapes against the real dump from Task 1 Step 7 and adjust the fixture's *spacing/labels* (never the real numbers) if the real layout differs:

```text
                         Malayan Banking Berhad (3813-K)
   STATEMENT DATE :   31/01/25
   123456-789012   ACCOUNT NUMBER
   ENTRY DATE     TRANSACTION DESCRIPTION        TRANSACTION AMOUNT    STATEMENT BALANCE
                  BEGINNING BALANCE                                    1,000.00
   02/01/25       FPX PAYMENT FR A/C                     150.00-         850.00
                  SHOPEE MALAYSIA
                  *
   15/01/25       TRANSFER TO A/C                      2,500.00+       3,350.00
                  ACME SDN BHD
                  SALARY JAN
   28/01/25       DEBIT CARD PURCHASE                       .50-       3,349.50
                  PARKING SELANGOR
                  ENDING BALANCE :                                     3,349.50
                  TOTAL DEBIT :  150.50
                  TOTAL CREDIT : 2,500.00
```

- [ ] **Step 2: Write the failing test**

`test/models/statement_parser/maybank_casa_test.rb`:

```ruby
require "test_helper"

class StatementParser::MaybankCasaTest < ActiveSupport::TestCase
  setup do
    @lines = file_fixture("statement_parser/maybank_casa.txt").read.lines.map(&:rstrip).reject(&:blank?)
  end

  test "recognises a CASA/MAE statement" do
    assert StatementParser::MaybankCasa.matches?(@lines)
    assert_not StatementParser::MaybankCasa.matches?([ "TNG WALLET TRANSACTION HISTORY" ])
  end

  test "parses header figures" do
    result = StatementParser::MaybankCasa.new(@lines).parse

    assert_equal "maybank_casa", result.parser_key
    assert_equal "bank_statement", result.document_type
    assert_equal "Maybank", result.institution_name
    assert_equal "9012", result.account_last4
    assert_equal "MYR", result.currency
    assert_not result.liability
    assert_equal Date.new(2025, 1, 31), result.period_end_on
    assert_equal Date.new(2025, 1, 1), result.period_start_on
    assert_equal BigDecimal("1000"), result.opening_balance
    assert_equal BigDecimal("3349.50"), result.closing_balance
    assert_equal BigDecimal("2500"), result.printed_total_credit
    assert_equal BigDecimal("150.50"), result.printed_total_debit
  end

  test "parses transactions with joined multi-line names and inflow-positive amounts" do
    txns = StatementParser::MaybankCasa.new(@lines).parse.transactions

    assert_equal 3, txns.size
    assert_equal [ Date.new(2025, 1, 2), Date.new(2025, 1, 15), Date.new(2025, 1, 28) ], txns.map(&:date)
    assert_equal [ BigDecimal("-150"), BigDecimal("2500"), BigDecimal("-0.50") ], txns.map(&:amount)
    assert_equal "FPX PAYMENT FR A/C SHOPEE MALAYSIA", txns[0].name
    assert_equal "TRANSFER TO A/C ACME SDN BHD SALARY JAN", txns[1].name
    assert_equal "DEBIT CARD PURCHASE PARKING SELANGOR", txns[2].name
    assert txns.all? { _1.notes.nil? }
  end

  test "the fixture reconciles" do
    assert StatementParser::MaybankCasa.new(@lines).parse.checks.all? { _1["matched"] }
  end

  test "an overdrawn opening balance is negative" do
    lines = @lines.map { _1.sub("1,000.00", "1,000.00DR") }
    assert_equal BigDecimal("-1000"), StatementParser::MaybankCasa.new(lines).parse.opening_balance
  end

  test "a statement without a date is unsupported" do
    lines = @lines.reject { _1.include?("STATEMENT DATE") }.map { _1.gsub(%r{/25}, "") }
    assert_raises(StatementParser::Unsupported) { StatementParser::MaybankCasa.new(lines).parse }
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `bin/rails test test/models/statement_parser/maybank_casa_test.rb`
Expected: ERROR `uninitialized constant StatementParser::MaybankCasa`.

- [ ] **Step 4: Implement**

`app/models/statement_parser/base.rb`:

```ruby
class StatementParser::Base
  def self.matches?(lines)
    lines.any? { |line| line.match?(self::FINGERPRINT) }
  end

  attr_reader :lines

  def initialize(lines)
    @lines = lines
  end

  private
    # "1,234.56" and ".50" both appear on Maybank statements.
    def money(text)
      BigDecimal("0#{text.delete(',')}")
    end

    def first_match(regex)
      lines.each do |line|
        match = line.match(regex)
        return match if match
      end
      nil
    end

    def printed_amount(regex)
      match = first_match(regex)
      match && money(match[1])
    end

    # Sums every matching line (a card statement repeats the balance per card,
    # as kwgn does). Capture 1 is the amount; a present capture 2 (DR/CR
    # suffix) makes it negative.
    def summed_balance(regex)
      matches = lines.filter_map { |line| line.match(regex) }
      return nil if matches.empty?

      matches.sum(BigDecimal("0")) { |match| match[2].present? ? -money(match[1]) : money(match[1]) }
    end

    # A date printed without a year belongs to the statement's year, unless its
    # month is after the statement month: then it is from the year before.
    def date_in_statement_year(day, month, statement_date)
      year = month > statement_date.month ? statement_date.year - 1 : statement_date.year
      Date.new(year, month, day)
    end

    def last4(text)
      text.to_s.gsub(/\D/, "").last(4).presence
    end

    def period_start_for(statement_date)
      statement_date.prev_month + 1.day
    end
end
```

`app/models/statement_parser/maybank_casa.rb`:

```ruby
# Maybank savings/current and MAE statements. Port of kwgn's
# MAYBANK_CASA_AND_MAE extractor.
class StatementParser::MaybankCasa < StatementParser::Base
  FINGERPRINT = /BEGINNING BALANCE/
  STATEMENT_DATE = %r{(?:STATEMENT DATE|TARIKH PENYATA)\D*(\d{2}/\d{2}/\d{2})}
  ANY_DATE = %r{(\d{2}/\d{2}/\d{2})}
  ACCOUNT_NUMBER = /ACCOUNT\s*NUMBER\s*:?\s*(\d{6}-\d{6}|\d{12})|(\d{6}-\d{6}|\d{12})\s*ACCOUNT\s*NUMBER/
  OPENING = /BEGINNING BALANCE\s*([\d,]+\.\d{2})(DR)?/
  CLOSING = /ENDING BALANCE\s*:?\s*([\d,]+\.\d{2})(DR)?/
  TOTAL_DEBIT = /TOTAL DEBIT\s*:?\s*([\d,]+\.\d{2})/
  TOTAL_CREDIT = /TOTAL CREDIT\s*:?\s*([\d,]+\.\d{2})/
  TRANSACTION = %r{\A\s*(\d{2}/\d{2}(?:/\d{2})?)\s+(.+?)\s+([\d,]*\.\d{2})([+-])\s+[\d,]*\.\d{2}(?:DR)?\s*\z}
  # Lines that end a transaction's description even when indented like one.
  STOP = /BEGINNING BALANCE|ENDING BALANCE|TOTAL (?:DEBIT|CREDIT)|STATEMENT DATE|TARIKH PENYATA|ACCOUNT\s*NUMBER|NOMBOR AKAUN/
  PUNCTUATION_ONLY = /\A[\W_]+\z/

  def parse
    statement_date = parse_statement_date
    raise StatementParser::Unsupported unless statement_date

    StatementParser::Result.new(
      parser_key: "maybank_casa",
      document_type: "bank_statement",
      institution_name: "Maybank",
      account_last4: account_last4,
      currency: "MYR",
      liability: false,
      period_start_on: period_start_for(statement_date),
      period_end_on: statement_date,
      opening_balance: summed_balance(OPENING),
      closing_balance: summed_balance(CLOSING),
      printed_total_credit: printed_amount(TOTAL_CREDIT),
      printed_total_debit: printed_amount(TOTAL_DEBIT),
      transactions: parse_transactions(statement_date)
    )
  end

  private
    def parse_statement_date
      match = first_match(STATEMENT_DATE) || first_match(ANY_DATE)
      match && Date.strptime(match[1], "%d/%m/%y")
    rescue Date::Error
      nil
    end

    def account_last4
      match = first_match(ACCOUNT_NUMBER)
      match && last4(match[1] || match[2])
    end

    def parse_transactions(statement_date)
      rows = []
      current = nil

      lines.each do |line|
        if (match = line.match(TRANSACTION))
          rows << current if current
          amount = money(match[3])
          current = {
            date: transaction_date(match[1], statement_date),
            amount: match[4] == "-" ? -amount : amount,
            descriptions: [ match[2].squish ],
            description_column: match.begin(2)
          }
        elsif current && continuation?(line, current[:description_column])
          current[:descriptions] << line.squish unless line.strip.match?(PUNCTUATION_ONLY)
        else
          rows << current if current
          current = nil
        end
      end
      rows << current if current

      rows.map do |row|
        StatementParser::Transaction.new(date: row[:date], amount: row[:amount], name: row[:descriptions].join(" "), notes: nil)
      end
    end

    def continuation?(line, description_column)
      line[/\A */].size >= description_column - 2 && !line.match?(STOP)
    end

    def transaction_date(text, statement_date)
      day, month, year = text.split("/").map(&:to_i)
      return Date.strptime(text, "%d/%m/%y") if year

      date_in_statement_year(day, month, statement_date)
    end
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `bin/rails test test/models/statement_parser/maybank_casa_test.rb`
Expected: 6 runs, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/models/statement_parser/base.rb app/models/statement_parser/maybank_casa.rb test/fixtures/files/statement_parser/maybank_casa.txt test/models/statement_parser/maybank_casa_test.rb
git commit -m "feat(statement-parser): Maybank CASA/MAE parser

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Maybank 2 credit card parser

Port of `kwgn-cli/extractor/mbb_2_cc/handler.go`. The first date column is used (as kwgn does). Charges are outflows (negative); `CR` lines are payments/refunds (positive). Balances are summed across repeated lines (supplementary cards), as kwgn does.

**Files:**
- Create: `app/models/statement_parser/maybank_credit_card.rb`
- Create: `test/fixtures/files/statement_parser/maybank_credit_card.txt`
- Test: `test/models/statement_parser/maybank_credit_card_test.rb`

**Interfaces:**
- Consumes: `StatementParser::Base` helpers (`money`, `first_match`, `printed_amount`, `summed_balance`, `date_in_statement_year`, `last4`, `period_start_for`) from Task 3.
- Produces: `StatementParser::MaybankCreditCard` with `parser_key "maybank_credit_card"`, `document_type "credit_card_statement"`, `institution_name "Maybank"`, `liability true`.

- [ ] **Step 1: Write the fixture**

`test/fixtures/files/statement_parser/maybank_credit_card.txt` (synthetic; card number fake). Check shapes against the Task 1 dump:

```text
   PENYATA AKAUN KAD KREDIT      Malayan Banking Berhad (3813-K)
   Statement Date/Tarikh Penyata    28 JAN 25
   MAYBANK 2 PLAT VISA    5412 XXXX XXXX 4321
   YOUR PREVIOUS STATEMENT BALANCE                    1,200.00
   28/12   27/12   SHOPEE MALAYSIA KUALA LUMPUR          85.90
   02/01   02/01   PAYMENT VIA MAYBANK2U              1,200.00CR
   15/01   14/01   GRAB* A-1234 PETALING JAYA            23.40
   TOTAL CREDIT THIS MONTH (JUMLAH KREDIT)            1,200.00
   TOTAL DEBIT THIS MONTH (JUMLAH DEBIT)                109.30
   SUB TOTAL/JUMLAH                                     109.30
```

- [ ] **Step 2: Write the failing test**

`test/models/statement_parser/maybank_credit_card_test.rb`:

```ruby
require "test_helper"

class StatementParser::MaybankCreditCardTest < ActiveSupport::TestCase
  setup do
    @lines = file_fixture("statement_parser/maybank_credit_card.txt").read.lines.map(&:rstrip).reject(&:blank?)
    @result = StatementParser::MaybankCreditCard.new(@lines).parse
  end

  test "recognises a Maybank credit card statement" do
    assert StatementParser::MaybankCreditCard.matches?(@lines)
    assert_not StatementParser::MaybankCreditCard.matches?(file_fixture("statement_parser/maybank_casa.txt").read.lines)
  end

  test "parses header figures" do
    assert_equal "maybank_credit_card", @result.parser_key
    assert_equal "credit_card_statement", @result.document_type
    assert_equal "4321", @result.account_last4
    assert @result.liability
    assert_equal Date.new(2025, 1, 28), @result.period_end_on
    assert_equal Date.new(2024, 12, 29), @result.period_start_on
    assert_equal BigDecimal("1200"), @result.opening_balance
    assert_equal BigDecimal("109.30"), @result.closing_balance
  end

  test "a December line on a January statement is dated last year" do
    assert_equal Date.new(2024, 12, 28), @result.transactions.first.date
    assert_equal Date.new(2025, 1, 2), @result.transactions.second.date
  end

  test "charges are outflows and CR lines are inflows" do
    assert_equal [ BigDecimal("-85.90"), BigDecimal("1200"), BigDecimal("-23.40") ], @result.transactions.map(&:amount)
    assert_equal "GRAB* A-1234 PETALING JAYA", @result.transactions.last.name
  end

  test "the fixture reconciles" do
    assert @result.checks.all? { _1["matched"] }
  end

  test "a credit balance is negative" do
    lines = @lines.map { _1.sub(/SUB TOTAL\/JUMLAH\s+109\.30/, "SUB TOTAL/JUMLAH   15.00CR") }
    assert_equal BigDecimal("-15"), StatementParser::MaybankCreditCard.new(lines).parse.closing_balance
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `bin/rails test test/models/statement_parser/maybank_credit_card_test.rb`
Expected: ERROR `uninitialized constant StatementParser::MaybankCreditCard`.

- [ ] **Step 4: Implement**

`app/models/statement_parser/maybank_credit_card.rb`:

```ruby
# Maybank 2 credit card statements. Port of kwgn's MAYBANK_2_CC extractor.
class StatementParser::MaybankCreditCard < StatementParser::Base
  FINGERPRINT = /PENYATA AKAUN KAD KREDIT/
  STATEMENT_DATE = /\b(\d{2})\s(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)\s(\d{2})\b/
  CARD_NUMBER = /\b\d{4}[ -]?(?:\d{4}|[X*]{4})[ -]?(?:\d{4}|[X*]{4})[ -]?(\d{4})\b/
  OPENING = /YOUR PREVIOUS STATEMENT BALANCE\s*([\d,]+\.\d{2})(CR)?/
  CLOSING = %r{SUB TOTAL/JUMLAH\s*([\d,]+\.\d{2})(CR)?}
  TOTAL_CREDIT = /TOTAL CREDIT THIS MONTH\s*\(JUMLAH KREDIT\)\s*([\d,]+\.\d{2})/
  TOTAL_DEBIT = /TOTAL DEBIT THIS MONTH\s*\(JUMLAH DEBIT\)\s*([\d,]+\.\d{2})/
  TRANSACTION = %r{\A\s*(\d{2})/(\d{2})\s+\d{2}/\d{2}\s+(.+?)\s+([\d,]+\.\d{2})(CR)?\s*\z}

  def parse
    statement_date = parse_statement_date
    raise StatementParser::Unsupported unless statement_date

    StatementParser::Result.new(
      parser_key: "maybank_credit_card",
      document_type: "credit_card_statement",
      institution_name: "Maybank",
      account_last4: last4(first_match(CARD_NUMBER)&.[](1)),
      currency: "MYR",
      liability: true,
      period_start_on: period_start_for(statement_date),
      period_end_on: statement_date,
      opening_balance: summed_balance(OPENING),
      closing_balance: summed_balance(CLOSING),
      printed_total_credit: printed_amount(TOTAL_CREDIT),
      printed_total_debit: printed_amount(TOTAL_DEBIT),
      transactions: parse_transactions(statement_date)
    )
  end

  private
    def parse_statement_date
      match = first_match(STATEMENT_DATE)
      match && Date.strptime("#{match[1]} #{match[2]} #{match[3]}", "%d %b %y")
    rescue Date::Error
      nil
    end

    def parse_transactions(statement_date)
      lines.filter_map do |line|
        match = line.match(TRANSACTION)
        next unless match

        amount = money(match[4])
        StatementParser::Transaction.new(
          date: date_in_statement_year(match[1].to_i, match[2].to_i, statement_date),
          amount: match[5] ? amount : -amount,
          name: match[3].squish,
          notes: nil
        )
      end
    end
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `bin/rails test test/models/statement_parser/maybank_credit_card_test.rb`
Expected: 6 runs, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/models/statement_parser/maybank_credit_card.rb test/fixtures/files/statement_parser/maybank_credit_card.txt test/models/statement_parser/maybank_credit_card_test.rb
git commit -m "feat(statement-parser): Maybank 2 credit card parser

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Touch 'n Go parser

kwgn's TNG regex splits on single spaces and depends on how the Go library ordered text runs; it does not survive a change of PDF library. This parser instead splits a row on runs of 2+ spaces (pdf-reader's column gaps) and classifies cells, so it does not depend on column order: the first `RM` cell is the amount, digit-only cells of 8+ are references (→ notes), status cells are dropped, everything else before the amount is the name. Rows whose status is failed/unsuccessful/reversed are skipped (kwgn imported them).

**Files:**
- Create: `app/models/statement_parser/touch_n_go.rb`
- Create: `test/fixtures/files/statement_parser/touch_n_go.txt`
- Test: `test/models/statement_parser/touch_n_go_test.rb`

**Interfaces:**
- Consumes: `StatementParser::Base#money`.
- Produces: `StatementParser::TouchNGo` with `parser_key "touch_n_go"`, `document_type "bank_statement"`, `institution_name "Touch 'n Go"`, `liability false`, no balances or printed totals (so no checks).

- [ ] **Step 1: Write the fixture**

`test/fixtures/files/statement_parser/touch_n_go.txt` (synthetic). **Compare with the real TNG dump from Task 1 Step 7 before continuing.** If real rows put the date somewhere other than the start of the line, or separate cells by a single space, change `ROW`/the split regex and this fixture to match the real shape, and note the change in the task report.

```text
   TNG WALLET TRANSACTION HISTORY
   Date               Status    Transaction Type   Reference            Description   Details              Amount (RM)   Wallet Balance
   01/02/2025 12:30   Success   Payment            20250201123000123    GRAB FOOD     Merchant payment     -RM25.50      RM74.50
   03/02/2025 08:15   Success   Reload             20250203081500456    Maybank2u     Reload via FPX       +RM100.00     RM174.50
   04/02/2025 09:00   Failed    Payment            20250204090000789    PLUS TOLL     Exit Toll: Sg Besi   -RM5.00       RM174.50
   05/02/2025 18:45   Success   Payment            20250205184500999    PLUS TOLL     Exit Toll: Sg Besi   -RM5.00       RM169.50
```

- [ ] **Step 2: Write the failing test**

`test/models/statement_parser/touch_n_go_test.rb`:

```ruby
require "test_helper"

class StatementParser::TouchNGoTest < ActiveSupport::TestCase
  setup do
    @lines = file_fixture("statement_parser/touch_n_go.txt").read.lines.map(&:rstrip).reject(&:blank?)
    @result = StatementParser::TouchNGo.new(@lines).parse
  end

  test "recognises a TNG history" do
    assert StatementParser::TouchNGo.matches?(@lines)
  end

  test "skips failed transactions" do
    assert_equal 3, @result.transactions.size
    assert_equal [ Date.new(2025, 2, 1), Date.new(2025, 2, 3), Date.new(2025, 2, 5) ], @result.transactions.map(&:date)
  end

  test "signs, names and references" do
    first, reload, toll = @result.transactions

    assert_equal BigDecimal("-25.50"), first.amount
    assert_equal "Payment GRAB FOOD Merchant payment", first.name
    assert_equal "20250201123000123", first.notes
    assert_equal BigDecimal("100"), reload.amount
    assert_equal "Payment PLUS TOLL Exit Toll: Sg Besi", toll.name
  end

  test "period comes from the transactions and there is nothing to check" do
    assert_equal Date.new(2025, 2, 1), @result.period_start_on
    assert_equal Date.new(2025, 2, 5), @result.period_end_on
    assert_nil @result.account_last4
    assert_empty @result.checks
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `bin/rails test test/models/statement_parser/touch_n_go_test.rb`
Expected: ERROR `uninitialized constant StatementParser::TouchNGo`.

- [ ] **Step 4: Implement**

`app/models/statement_parser/touch_n_go.rb`:

```ruby
# Touch 'n Go eWallet transaction history.
class StatementParser::TouchNGo < StatementParser::Base
  FINGERPRINT = /TNG WALLET TRANSACTION HISTORY/i
  ROW = %r{\A\s*(\d{2}/\d{2}/\d{4})(?:\s+\d{2}:\d{2})?\s{2,}(.+)\z}
  CELL_SEPARATOR = /\s{2,}/
  AMOUNT = /\A([+-])?RM\s?([\d,]+\.\d{2})\z/
  STATUS = /\A(?:success(?:ful)?|fail(?:ed)?|unsuccessful|reversed|pending)\z/i
  NOT_SETTLED = /\A(?:fail|unsuccessful|reversed)/i
  REFERENCE = /\A\d{8,}\z/

  def parse
    transactions = lines.filter_map { |line| parse_row(line) }
    dates = transactions.map(&:date)

    StatementParser::Result.new(
      parser_key: "touch_n_go",
      document_type: "bank_statement",
      institution_name: "Touch 'n Go",
      account_last4: nil,
      currency: "MYR",
      liability: false,
      period_start_on: dates.min,
      period_end_on: dates.max,
      opening_balance: nil,
      closing_balance: nil,
      printed_total_credit: nil,
      printed_total_debit: nil,
      transactions: transactions
    )
  end

  private
    def parse_row(line)
      match = line.match(ROW)
      return unless match

      cells = match[2].split(CELL_SEPARATOR).map(&:strip)
      amount_index = cells.index { |cell| cell.match?(AMOUNT) }
      return unless amount_index

      described = cells.first(amount_index)
      return if described.any? { |cell| cell.match?(NOT_SETTLED) }

      amount_match = cells[amount_index].match(AMOUNT)
      amount = money(amount_match[2])
      references, words = described.reject { |cell| cell.match?(STATUS) }.partition { |cell| cell.match?(REFERENCE) }

      StatementParser::Transaction.new(
        date: Date.strptime(match[1], "%d/%m/%Y"),
        amount: amount_match[1] == "-" ? -amount : amount,
        name: words.join(" "),
        notes: references.join(" ").presence
      )
    end
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `bin/rails test test/models/statement_parser/touch_n_go_test.rb`
Expected: 4 runs, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/models/statement_parser/touch_n_go.rb test/fixtures/files/statement_parser/touch_n_go.txt test/models/statement_parser/touch_n_go_test.rb
git commit -m "feat(statement-parser): Touch 'n Go parser

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Parser dispatch

**Files:**
- Modify: `app/models/statement_parser.rb`
- Test: `test/models/statement_parser_test.rb`

**Interfaces:**
- Produces: `StatementParser.parsers -> Array<Class>` (order: credit card, CASA, TNG) and `StatementParser.parse(content, password: nil) -> StatementParser::Result`, raising `PasswordRequired | WrongPassword | Unreadable | Unsupported`.

- [ ] **Step 1: Write the failing test**

`test/models/statement_parser_test.rb`:

```ruby
require "test_helper"

class StatementParserTest < ActiveSupport::TestCase
  def fixture_lines(name)
    file_fixture("statement_parser/#{name}.txt").read.lines.map(&:rstrip).reject(&:blank?)
  end

  test "dispatches to the parser whose fingerprint matches" do
    { "maybank_casa" => "maybank_casa", "maybank_credit_card" => "maybank_credit_card", "touch_n_go" => "touch_n_go" }.each do |fixture, key|
      StatementParser::TextExtractor.stubs(:lines).returns(fixture_lines(fixture))
      assert_equal key, StatementParser.parse("pdf-bytes").parser_key
    end
  end

  test "unrecognised statements are unsupported" do
    assert_raises(StatementParser::Unsupported) do
      StatementParser.parse(file_fixture("imports/sample_bank_statement.pdf").binread)
    end
  end

  test "passes the password through" do
    StatementParser::TextExtractor.expects(:lines).with("pdf-bytes", password: "pw").returns(fixture_lines("touch_n_go"))
    StatementParser.parse("pdf-bytes", password: "pw")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/models/statement_parser_test.rb`
Expected: ERROR `undefined method 'parse' for module StatementParser`.

- [ ] **Step 3: Implement** — append inside `module StatementParser` in `app/models/statement_parser.rb`:

```ruby
  # Most specific fingerprint first: a card statement also carries Maybank's
  # bank header, so it must be tried before CASA.
  def self.parsers
    [ MaybankCreditCard, MaybankCasa, TouchNGo ]
  end

  def self.parse(content, password: nil)
    lines = TextExtractor.lines(content, password: password)
    parser = parsers.find { |klass| klass.matches?(lines) }
    raise Unsupported unless parser

    parser.new(lines).parse
  end
```

- [ ] **Step 4: Run all parser tests**

Run: `bin/rails test test/models/statement_parser_test.rb test/models/statement_parser`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add app/models/statement_parser.rb test/models/statement_parser_test.rb
git commit -m "feat(statement-parser): dispatch by fingerprint

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: PdfImport accepts a parse result

**Files:**
- Create: `app/models/pdf_import/statement_parsing.rb`
- Modify: `app/models/pdf_import.rb` (include concern; split `create_from_upload!`; `configured?`)
- Test: `test/models/pdf_import_statement_parsing_test.rb`

**Interfaces:**
- Consumes: `StatementParser.parse`, `StatementParser::Result#checks` and its fields.
- Produces (class): `PdfImport.ai_processing_enabled? -> bool`; `PdfImport.create_from_prepared_upload!(family:, prepared_upload:, user:) -> PdfImport`.
- Produces (instance): `#apply_parse_result!(result)`, `#mark_password_required!`, `#parse_statement!(password:) -> :parsed | :wrong_password | :password_required | :unsupported`, `#discard_unparsed!`, `#parsed? #password_required? #processed? -> bool`, `#statement_checks -> Array<Hash>`, `#statement_checks_mismatched? -> bool`.
- Stored shape: `extracted_data = { "parser" => key, "transactions" => [{ "date" => "YYYY-MM-DD", "amount" => "-150.0", "name", "notes", "category" => "" }], "checks" => [...] }`; password-required state is `{ "parse_status" => "password_required" }`.

- [ ] **Step 1: Write the failing test**

`test/models/pdf_import_statement_parsing_test.rb`:

```ruby
require "test_helper"

class PdfImportStatementParsingTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @import = PdfImport.create_from_prepared_upload!(family: @family, prepared_upload: prepared_upload, user: @user)
  end

  test "applying a result stores rows, statement metadata and checks without touching AI state" do
    @import.apply_parse_result!(casa_result)
    @import.reload

    assert @import.parsed?
    assert @import.processed?
    assert_nil @import.ai_summary
    assert_equal "bank_statement", @import.document_type
    assert_equal "pending", @import.status
    assert_equal 2, @import.rows_count
    assert @import.configured?
    assert_equal [ "-150.0", "2500.0" ], @import.rows.order(:source_row_number).pluck(:amount)
    assert_equal "FPX PAYMENT SHOPEE", @import.rows.order(:source_row_number).first.name
    assert_not @import.statement_checks_mismatched?

    statement = @import.account_statement
    assert_equal "9012", statement.account_last4_hint
    assert_equal "Maybank", statement.institution_name_hint
    assert_equal Date.new(2025, 1, 1), statement.period_start_on
    assert_equal Date.new(2025, 1, 31), statement.period_end_on
    assert_equal BigDecimal("3350"), statement.closing_balance.to_d
  end

  test "mismatched printed totals are flagged" do
    @import.apply_parse_result!(casa_result(printed_total_debit: BigDecimal("999")))
    assert @import.reload.statement_checks_mismatched?
  end

  test "an empty statement completes" do
    @import.apply_parse_result!(casa_result(transactions: [], printed_total_credit: nil, printed_total_debit: nil, closing_balance: nil))
    assert_equal "complete", @import.reload.status
  end

  test "password-required state" do
    @import.mark_password_required!
    assert @import.reload.password_required?
    assert_not @import.parsed?
  end

  test "parse_statement! with the right password applies the result" do
    @import.mark_password_required!
    StatementParser.expects(:parse).with(@import.pdf_file_content, password: "pw").returns(casa_result)

    assert_equal :parsed, @import.parse_statement!(password: "pw")
    assert @import.reload.parsed?
  end

  test "parse_statement! with a wrong password changes nothing" do
    @import.mark_password_required!
    StatementParser.stubs(:parse).raises(StatementParser::WrongPassword)

    assert_equal :wrong_password, @import.parse_statement!(password: "nope")
    assert @import.reload.password_required?
  end

  test "parse_statement! does not re-parse a parsed import" do
    @import.apply_parse_result!(casa_result)
    StatementParser.expects(:parse).never

    assert_equal :parsed, @import.parse_statement!(password: nil)
  end

  test "re-uploading the same file reuses the parsed import" do
    @import.apply_parse_result!(casa_result)

    again = PdfImport.create_from_prepared_upload!(family: @family, prepared_upload: prepared_upload, user: @user)

    assert_equal @import, again
    assert again.parsed?
    assert_equal 2, again.rows_count
  end

  test "discarding an unparsed import removes its unlinked statement" do
    statement = @import.account_statement

    assert_difference [ "Import.count", "AccountStatement.count" ], -1 do
      @import.discard_unparsed!
    end
    assert_not AccountStatement.exists?(statement.id)
  end

  test "the AI path is off unless PDF_IMPORT_AI is set" do
    ClimateControl.modify(PDF_IMPORT_AI: nil) { assert_not PdfImport.ai_processing_enabled? }
    ClimateControl.modify(PDF_IMPORT_AI: "true") { assert PdfImport.ai_processing_enabled? }
  end

  private
    def prepared_upload
      AccountStatement.prepare_upload!(
        uploaded_file(
          filename: "maybank.pdf",
          content_type: "application/pdf",
          content: file_fixture("imports/sample_bank_statement.pdf").binread
        )
      )
    end

    def casa_result(**overrides)
      StatementParser::Result.new(**{
        parser_key: "maybank_casa", document_type: "bank_statement", institution_name: "Maybank",
        account_last4: "9012", currency: "MYR", liability: false,
        period_start_on: Date.new(2025, 1, 1), period_end_on: Date.new(2025, 1, 31),
        opening_balance: BigDecimal("1000"), closing_balance: BigDecimal("3350"),
        printed_total_credit: BigDecimal("2500"), printed_total_debit: BigDecimal("150"),
        transactions: [
          StatementParser::Transaction.new(date: Date.new(2025, 1, 2), amount: BigDecimal("-150"), name: "FPX PAYMENT SHOPEE", notes: nil),
          StatementParser::Transaction.new(date: Date.new(2025, 1, 15), amount: BigDecimal("2500"), name: "SALARY", notes: nil)
        ]
      }.merge(overrides))
    end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/models/pdf_import_statement_parsing_test.rb`
Expected: ERROR `undefined method 'create_from_prepared_upload!'`.

- [ ] **Step 3: Implement the concern**

`app/models/pdf_import/statement_parsing.rb`:

```ruby
# Fork-only: deterministic statement parsing for PdfImport (see
# StatementParser). Feeds the same extracted_data -> rows pipeline the AI path
# uses, but runs in-process and never reaches ProcessPdfJob, an LLM provider or
# the vector store.
module PdfImport::StatementParsing
  extend ActiveSupport::Concern

  class_methods do
    # Upstream's AI extraction stays in the code for cheap rebases, but is only
    # reachable when explicitly switched on.
    def ai_processing_enabled?
      ActiveModel::Type::Boolean.new.cast(ENV.fetch("PDF_IMPORT_AI", "false")) || false
    end
  end

  def parsed?
    extracted_data.is_a?(Hash) && extracted_data["parser"].present?
  end

  def password_required?
    extracted_data.is_a?(Hash) && extracted_data["parse_status"] == "password_required"
  end

  def processed?
    ai_processed? || parsed?
  end

  def statement_checks
    parsed? ? Array(extracted_data["checks"]) : []
  end

  def statement_checks_mismatched?
    statement_checks.any? { |check| !check["matched"] }
  end

  # The password is used for this call only and never stored.
  def parse_statement!(password: nil)
    return :parsed if parsed?

    apply_parse_result!(StatementParser.parse(pdf_file_content, password: password))
    :parsed
  rescue StatementParser::WrongPassword
    :wrong_password
  rescue StatementParser::PasswordRequired
    :password_required
  rescue StatementParser::Unsupported, StatementParser::Unreadable
    :unsupported
  end

  def apply_parse_result!(result)
    transaction do
      update!(
        document_type: result.document_type,
        extracted_data: {
          "parser" => result.parser_key,
          "transactions" => result.transactions.map { |txn| serialize_transaction(txn) },
          "checks" => result.checks
        }
      )
      apply_statement_metadata!(result)
      generate_rows_from_extracted_data
      sync_mappings
      update!(status: rows_count.positive? ? :pending : :complete)
    end
  end

  def mark_password_required!
    update!(status: :pending, extracted_data: { "parse_status" => "password_required" })
  end

  # For an upload that turned out not to be a supported statement once
  # decrypted: nothing was extracted, so nothing is worth keeping.
  def discard_unparsed!
    statement = account_statement
    destroy!
    statement.destroy! if statement && statement.account_id.nil? && statement.pdf_imports.reload.none?
  end

  private
    def serialize_transaction(txn)
      {
        "date" => txn.date.iso8601,
        "amount" => txn.amount.to_s("F"),
        "name" => txn.name,
        "notes" => txn.notes.to_s,
        "category" => ""
      }
    end

    def apply_statement_metadata!(result)
      statement = account_statement
      return unless statement

      statement.assign_attributes(
        institution_name_hint: result.institution_name,
        account_last4_hint: result.account_last4,
        currency: result.currency,
        period_start_on: result.period_start_on,
        period_end_on: result.period_end_on,
        opening_balance: result.opening_balance,
        closing_balance: result.closing_balance
      )
      statement.assign_account_match if statement.account_id.nil?
      statement.save!
    end
end
```

- [ ] **Step 4: Wire it into PdfImport** (`app/models/pdf_import.rb`)

After `class PdfImport < Import`, add:

```ruby
  include PdfImport::StatementParsing
```

Replace the body of `create_from_upload!` and add `create_from_prepared_upload!` next to it:

```ruby
    def create_from_upload!(family:, file:, user:)
      create_from_prepared_upload!(family: family, prepared_upload: AccountStatement.prepare_upload!(file), user: user)
    end

    def create_from_prepared_upload!(family:, prepared_upload:, user:)
      statement = AccountStatement.create_from_prepared_upload!(
        family: family,
        account: nil,
        prepared_upload: prepared_upload
      )

      create_from_statement!(statement: statement)
    rescue AccountStatement::DuplicateUploadError => e
      raise unless e.statement.manageable_by?(user)

      create_from_statement!(statement: e.statement)
    end
```

Change `configured?`:

```ruby
  def configured?
    processed? && rows_count > 0
  end
```

- [ ] **Step 5: Run the new and existing PdfImport tests**

Run: `bin/rails test test/models/pdf_import_statement_parsing_test.rb test/models/pdf_import_test.rb test/models/pdf_import_reconciliation_test.rb test/jobs/process_pdf_job_test.rb`
Expected: all pass. If "re-uploading the same file reuses the parsed import" fails because `create_from_statement!` builds a new import (its reuse test compares `account_id` and `date_format`), inspect `AccountStatement#latest_reusable_pdf_import` and report — do not weaken the test.

- [ ] **Step 6: Commit**

```bash
git add app/models/pdf_import/statement_parsing.rb app/models/pdf_import.rb test/models/pdf_import_statement_parsing_test.rb
git commit -m "feat(pdf-import): accept deterministic statement parse results

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Upload flow parses first, never touches the AI path or vector store

**Files:**
- Modify: `app/controllers/imports_controller.rb` (`create_pdf_import`, `create_document_import`, `document_upload_supported_extensions`)
- Modify: `config/locales/views/imports/en.yml` (under `en.imports.create`)
- Modify: `test/controllers/imports_controller_test.rb`

**Interfaces:**
- Consumes: `StatementParser.parse`, `PdfImport.create_from_prepared_upload!`, `#apply_parse_result!`, `#mark_password_required!`, `#parsed?`, `PdfImport.ai_processing_enabled?`.

- [ ] **Step 1: Keep the upstream AI-path tests meaningful**

In `test/controllers/imports_controller_test.rb`, at the top of each of these existing tests add `PdfImport.stubs(:ai_processing_enabled?).returns(true)` (they upload a non-Malaysian sample PDF and assert the AI flow): "uploads pdf document as PdfImport when using DocumentImport option", "uploads pdf import through account statement", and any other test asserting `imports.create.pdf_processing` (find them with `grep -n "pdf_processing" test/controllers/imports_controller_test.rb`).

- [ ] **Step 2: Write the failing tests** (append to `ImportsControllerTest`)

```ruby
  test "a supported statement is parsed in the request and never reaches AI or the vector store" do
    StatementParser.stubs(:parse).returns(parsed_statement_result)
    ProcessPdfJob.expects(:perform_later).never
    Family.any_instance.expects(:upload_document).never

    assert_difference "PdfImport.count", 1 do
      post imports_url, params: { import: { import_file: file_fixture_upload("imports/sample_bank_statement.pdf", "application/pdf") } }
    end

    created = PdfImport.order(:created_at).last
    assert created.parsed?
    assert_nil created.ai_summary
    assert_redirected_to import_url(created)
    assert_equal I18n.t("imports.create.pdf_parsed"), flash[:notice]
  end

  test "an unsupported statement is rejected without saving anything when AI is off" do
    PdfImport.stubs(:ai_processing_enabled?).returns(false)
    ProcessPdfJob.expects(:perform_later).never

    assert_no_difference [ "Import.count", "AccountStatement.count" ] do
      post imports_url, params: { import: { import_file: file_fixture_upload("imports/sample_bank_statement.pdf", "application/pdf") } }
    end

    assert_redirected_to new_import_url
    assert_equal I18n.t("imports.create.pdf_unsupported"), flash[:alert]
  end

  test "a protected statement is stored and asks for its password" do
    assert_difference "PdfImport.count", 1 do
      post imports_url, params: { import: { import_file: file_fixture_upload("imports/sample_bank_statement_encrypted.pdf", "application/pdf") } }
    end

    created = PdfImport.order(:created_at).last
    assert created.password_required?
    assert_redirected_to import_url(created)
  end

  test "the PDF option is offered with no vector store configured" do
    VectorStore::Registry.stubs(:adapter).returns(nil)

    get new_import_url

    assert_response :success
    assert_select "input[type=file][accept*='.pdf']"
  end

  test "a PDF sent through the document option with no vector store is still parsed" do
    VectorStore::Registry.stubs(:adapter).returns(nil)
    StatementParser.stubs(:parse).returns(parsed_statement_result)

    assert_difference "PdfImport.count", 1 do
      post imports_url, params: { import: { type: "DocumentImport", import_file: file_fixture_upload("imports/sample_bank_statement.pdf", "application/pdf") } }
    end
  end

  private
    def parsed_statement_result
      StatementParser::Result.new(
        parser_key: "maybank_casa", document_type: "bank_statement", institution_name: "Maybank",
        account_last4: "9012", currency: "MYR", liability: false,
        period_start_on: Date.new(2025, 1, 1), period_end_on: Date.new(2025, 1, 31),
        opening_balance: BigDecimal("1000"), closing_balance: BigDecimal("850"),
        printed_total_credit: nil, printed_total_debit: BigDecimal("150"),
        transactions: [ StatementParser::Transaction.new(date: Date.new(2025, 1, 2), amount: BigDecimal("-150"), name: "FPX PAYMENT SHOPEE", notes: nil) ]
      )
    end
```

(If the test class already has a `private` section, put `parsed_statement_result` inside it instead of adding a second one.)

- [ ] **Step 3: Run to verify they fail**

Run: `bin/rails test test/controllers/imports_controller_test.rb`
Expected: the five new tests fail (missing translation / AI path still used / no PDF option); the stubbed upstream tests pass.

- [ ] **Step 4: Implement the controller changes** (`app/controllers/imports_controller.rb`)

Replace `create_pdf_import`:

```ruby
    # Fork: statements are parsed in-process (StatementParser). The upstream AI
    # path is used only for unrecognised PDFs, and only when PDF_IMPORT_AI is on.
    def create_pdf_import(file)
      return redirect_to new_import_path, alert: t("accounts.not_authorized") unless AccountStatement.statement_manager?(Current.user)
      return redirect_to new_import_path, alert: t("imports.create.pdf_too_large", max_size: Import::MAX_PDF_SIZE / 1.megabyte) if file.size > Import::MAX_PDF_SIZE

      prepared_upload = AccountStatement.prepare_upload!(file)
      outcome =
        begin
          StatementParser.parse(prepared_upload.content)
        rescue StatementParser::PasswordRequired
          :password_required
        rescue StatementParser::Unsupported, StatementParser::Unreadable, StatementParser::WrongPassword
          :unsupported
        end

      if outcome == :unsupported && !PdfImport.ai_processing_enabled?
        return redirect_to new_import_path, alert: t("imports.create.pdf_unsupported")
      end

      pdf_import = PdfImport.create_from_prepared_upload!(family: Current.family, prepared_upload: prepared_upload, user: Current.user)

      case outcome
      when StatementParser::Result
        pdf_import.apply_parse_result!(outcome) unless pdf_import.parsed?
        redirect_to import_path(pdf_import), notice: t("imports.create.pdf_parsed")
      when :password_required
        pdf_import.mark_password_required! unless pdf_import.parsed?
        redirect_to import_path(pdf_import)
      else
        pdf_import.process_with_ai_later
        redirect_to import_path(pdf_import), notice: t("imports.create.pdf_processing")
      end
    rescue AccountStatement::DuplicateUploadError
      redirect_to new_import_path, alert: t("imports.create.duplicate_pdf_unavailable")
    rescue AccountStatement::InvalidUploadError
      redirect_to new_import_path, alert: t("imports.create.invalid_pdf")
    end
```

In `create_document_import`, move the PDF branch to the very top of the method so a PDF never depends on (or reaches) the vector store:

```ruby
    def create_document_import(file)
      if File.extname(file.original_filename.to_s).downcase == ".pdf"
        return redirect_to new_import_path, alert: t("imports.create.invalid_pdf") unless valid_pdf_file?(file)

        return create_pdf_import(file)
      end

      adapter = VectorStore.adapter
      # ... rest of the existing method unchanged, minus the old `if ext == ".pdf"` block
```

Delete the old `if ext == ".pdf" ... end` block further down that method.

Replace `document_upload_supported_extensions`:

```ruby
    def document_upload_supported_extensions
      adapter = VectorStore.adapter
      extensions = adapter ? adapter.supported_extensions.map(&:downcase) : []
      (extensions | [ ".pdf" ]).uniq.sort
    end
```

- [ ] **Step 5: Add locale keys** — in `config/locales/views/imports/en.yml`, under `en: imports: create:` (next to `pdf_processing`):

```yaml
      pdf_parsed: Statement read. Review the transactions before importing.
      pdf_unsupported: "Unsupported statement format. Supported: Maybank savings/current/MAE, Maybank credit card and Touch 'n Go e-statements."
```

- [ ] **Step 6: Run tests**

Run: `bin/rails test test/controllers/imports_controller_test.rb test/i18n_test.rb`
Expected: all pass. If `i18n_test` flags the file as not normalized, run `bundle exec i18n-tasks normalize` and re-run.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/imports_controller.rb config/locales/views/imports/en.yml test/controllers/imports_controller_test.rb
git commit -m "feat(imports): parse statements in-process; AI path only behind PDF_IMPORT_AI

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Password prompt and review-screen checks

**Files:**
- Create: `app/controllers/import/pdf_passwords_controller.rb`, `app/views/imports/_pdf_password_form.html.erb`, `app/views/imports/_pdf_statement_checks.html.erb`
- Modify: `config/routes.rb` (inside `resources :imports do`), `app/views/imports/_pdf_import.html.erb`, `config/locales/views/imports/en.yml`
- Test: `test/controllers/import/pdf_passwords_controller_test.rb`, append to `test/controllers/imports_controller_test.rb`

**Interfaces:**
- Consumes: `PdfImport#parse_statement!(password:)`, `#discard_unparsed!`, `#password_required?`, `#statement_checks`, `#statement_checks_mismatched?`, `AccountStatement#reconciliation_checks` (returns `[{ key:, statement_amount:, ledger_amount:, difference:, status: }]`), `AccountStatement#suggested_account_id`.
- Produces: route `PATCH /imports/:import_id/pdf_password` → `import_pdf_password_path(import)`, param `password`.

- [ ] **Step 1: Write the failing controller test**

`test/controllers/import/pdf_passwords_controller_test.rb`:

```ruby
require "test_helper"

class Import::PdfPasswordsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @import = PdfImport.create_from_prepared_upload!(
      family: @user.family,
      prepared_upload: AccountStatement.prepare_upload!(
        uploaded_file(filename: "locked.pdf", content_type: "application/pdf",
                      content: file_fixture("imports/sample_bank_statement_encrypted.pdf").binread)
      ),
      user: @user
    )
    @import.mark_password_required!
  end

  test "right password parses the statement" do
    PdfImport.any_instance.expects(:parse_statement!).with(password: "test1234").returns(:parsed)

    patch import_pdf_password_url(@import), params: { password: "test1234" }

    assert_redirected_to import_url(@import)
    assert_equal I18n.t("imports.pdf_password.parsed"), flash[:notice]
  end

  test "wrong password asks again and never echoes it" do
    patch import_pdf_password_url(@import), params: { password: "not-it-123" }

    assert_redirected_to import_url(@import)
    assert_equal I18n.t("imports.pdf_password.wrong_password"), flash[:alert]
    assert_not_includes flash[:alert], "not-it-123"
    assert @import.reload.password_required?
  end

  test "a decrypted but unsupported statement is discarded" do
    # sample_bank_statement is not a Malaysian statement, so the real parser rejects it.
    assert_difference "PdfImport.count", -1 do
      patch import_pdf_password_url(@import), params: { password: "test1234" }
    end

    assert_redirected_to new_import_url
    assert_equal I18n.t("imports.create.pdf_unsupported"), flash[:alert]
  end

  test "the password is filtered from logs" do
    assert_includes Rails.application.config.filter_parameters.map(&:to_s), "passw"
  end
end
```

Append to `test/controllers/imports_controller_test.rb`:

```ruby
  test "a password-required import shows the password form" do
    import = PdfImport.create_from_prepared_upload!(
      family: @user.family,
      prepared_upload: AccountStatement.prepare_upload!(
        uploaded_file(filename: "locked.pdf", content_type: "application/pdf",
                      content: file_fixture("imports/sample_bank_statement_encrypted.pdf").binread)
      ),
      user: @user
    )
    import.mark_password_required!

    get import_url(import)

    assert_select "form[action='#{import_pdf_password_path(import)}'] input[type=password][name=password]"
  end

  test "a parsed import with mismatched totals shows the warning" do
    StatementParser.stubs(:parse).returns(parsed_statement_result)
    post imports_url, params: { import: { import_file: file_fixture_upload("imports/sample_bank_statement.pdf", "application/pdf") } }
    import = PdfImport.order(:created_at).last
    import.update!(extracted_data: import.extracted_data.merge("checks" => [ { "key" => "total_debit", "printed" => "150.0", "parsed" => "100.0", "matched" => false } ]))

    get import_url(import)

    assert_select "[data-testid='pdf-statement-checks-warning']"
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/controllers/import/pdf_passwords_controller_test.rb test/controllers/imports_controller_test.rb`
Expected: route/constant errors and missing selectors.

- [ ] **Step 3: Route** — in `config/routes.rb`, inside `resources :imports ... do`, next to `resource :upload`:

```ruby
    resource :pdf_password, only: :update, module: :import
```

- [ ] **Step 4: Controller**

`app/controllers/import/pdf_passwords_controller.rb`:

```ruby
# Fork: receives the password for a protected statement. The password is used
# for this request's parse only -- never stored, queued or echoed back.
class Import::PdfPasswordsController < ApplicationController
  before_action :set_import

  def update
    case @import.parse_statement!(password: params[:password].to_s)
    when :parsed
      redirect_to import_path(@import), notice: t("imports.pdf_password.parsed")
    when :wrong_password, :password_required
      redirect_to import_path(@import), alert: t("imports.pdf_password.wrong_password")
    else
      @import.discard_unparsed!
      redirect_to new_import_path, alert: t("imports.create.pdf_unsupported")
    end
  end

  private
    def set_import
      @import = Current.family.imports.where(type: "PdfImport").find(params[:import_id])
      statement = @import.account_statement
      raise ActiveRecord::RecordNotFound if statement.present? && !statement.manageable_by?(Current.user)
    end
end
```

- [ ] **Step 5: Views**

`app/views/imports/_pdf_password_form.html.erb`:

```erb
<%# locals: (import:) %>
<div class="mx-auto bg-warning/10 h-8 w-8 rounded-full flex items-center justify-center">
  <%= icon "lock", class: "text-warning" %>
</div>

<div class="text-center space-y-2">
  <h1 class="font-medium text-primary text-center text-3xl"><%= t("imports.pdf_password.title") %></h1>
  <p class="text-sm text-secondary"><%= t("imports.pdf_password.description", filename: import.pdf_filename) %></p>
</div>

<%= styled_form_with url: import_pdf_password_path(import), method: :patch, class: "space-y-3" do |form| %>
  <%= form.password_field :password, name: "password", label: t("imports.pdf_password.label"), autocomplete: "off", required: true, autofocus: true %>
  <%= form.submit t("imports.pdf_password.submit") %>
<% end %>

<%= render DS::Link.new(text: t("imports.pdf_import.back_to_imports"), href: imports_path, variant: "secondary", full_width: true) %>
```

`app/views/imports/_pdf_statement_checks.html.erb`:

```erb
<%# locals: (import:) %>
<% statement = import.account_statement %>
<% ledger_checks = statement&.account.present? ? statement.reconciliation_checks : [] %>

<% if import.statement_checks_mismatched? %>
  <div class="text-sm px-3 py-2 bg-warning/10 rounded-lg space-y-1" data-testid="pdf-statement-checks-warning">
    <p class="font-medium text-primary"><%= t("imports.pdf_statement_checks.mismatch_title") %></p>
    <% import.statement_checks.reject { _1["matched"] }.each do |check| %>
      <p class="text-secondary">
        <%= t("imports.pdf_statement_checks.keys.#{check['key']}") %>:
        <%= t("imports.pdf_statement_checks.printed_vs_parsed", printed: check["printed"], parsed: check["parsed"]) %>
      </p>
    <% end %>
  </div>
<% end %>

<% if ledger_checks.any? %>
  <div class="space-y-2">
    <h2 class="font-medium text-primary"><%= t("imports.pdf_statement_checks.ledger_title") %></h2>
    <% ledger_checks.each do |check| %>
      <p class="text-sm text-secondary px-3 py-2 bg-container-inset rounded-lg">
        <%= t("imports.pdf_statement_checks.keys.#{check[:key]}") %>:
        <%= t("imports.pdf_statement_checks.statement_vs_ledger",
              statement: check[:statement_amount].to_s("F"),
              ledger: check[:ledger_amount].to_s("F"),
              difference: check[:difference].to_s("F")) %>
      </p>
    <% end %>
  </div>
<% end %>
```

Edit `app/views/imports/_pdf_import.html.erb`:

1. Change the first branch line `<% if import.pending? && import.rows_count > 0 %>` to:

```erb
    <% if import.password_required? %>
      <%= render "imports/pdf_password_form", import: import %>
    <% elsif import.pending? && import.rows_count > 0 %>
```

2. Directly after the closing `</div>` of the "transactions extracted" block (the one containing `transactions_extracted_count`), add:

```erb
        <%= render "imports/pdf_statement_checks", import: import %>
```

3. In the account `f.select`, change `selected: import.account_id` to:

```erb
selected: import.account_id || import.account_statement&.suggested_account_id
```

- [ ] **Step 6: Locale keys** — `config/locales/views/imports/en.yml`, under `en: imports:`:

```yaml
    pdf_password:
      title: This statement is password-protected
      description: "Enter the password for %{filename}. It is used once to read the statement and is not saved."
      label: PDF password
      submit: Unlock and read
      parsed: Statement read. Review the transactions before importing.
      wrong_password: That password did not open the statement. Try again.
    pdf_statement_checks:
      mismatch_title: The parsed transactions do not add up to the statement's printed figures. Some lines may have been missed — review before importing.
      printed_vs_parsed: "statement %{printed}, parsed %{parsed}"
      ledger_title: Statement vs account balance
      statement_vs_ledger: "statement %{statement}, account %{ledger} (difference %{difference})"
      keys:
        total_credit: Total credit
        total_debit: Total debit
        closing_balance: Closing balance
        opening_balance: Opening balance
        period_movement: Movement in period
```

- [ ] **Step 7: Run tests**

Run: `bin/rails test test/controllers/import/pdf_passwords_controller_test.rb test/controllers/imports_controller_test.rb test/i18n_test.rb`
Expected: all pass.

- [ ] **Step 8: Manual check in the browser** (use the `run` skill or `bin/dev`): upload `test/fixtures/files/imports/sample_bank_statement_encrypted.pdf` → password form appears; wrong password → alert, form again; `test1234` → "Unsupported statement format" and the import is gone. Confirm the password does not appear in `log/development.log` (`grep -c test1234 log/development.log` → 0).

- [ ] **Step 9: Lint and commit**

```bash
bin/rubocop -a app/controllers/import/pdf_passwords_controller.rb
bundle exec erb_lint app/views/imports/_pdf_password_form.html.erb app/views/imports/_pdf_statement_checks.html.erb app/views/imports/_pdf_import.html.erb -a
git add app/controllers/import/pdf_passwords_controller.rb app/views/imports/_pdf_password_form.html.erb app/views/imports/_pdf_statement_checks.html.erb app/views/imports/_pdf_import.html.erb config/routes.rb config/locales/views/imports/en.yml test/controllers/import/pdf_passwords_controller_test.rb test/controllers/imports_controller_test.rb
git commit -m "feat(pdf-import): password prompt, totals warning and account suggestion

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Run family rules on the imported transactions after publish

**Files:**
- Modify: `app/models/rule.rb` (`apply`, `matching_resources_scope`)
- Modify: `app/models/pdf_import/statement_parsing.rb`, `app/models/pdf_import.rb` (`import!`)
- Test: `test/models/rule_test.rb`, `test/models/pdf_import_statement_parsing_test.rb`

**Interfaces:**
- Produces: `Rule#apply(ignore_attribute_locks: false, rule_run: nil, transaction_ids: nil)` — when `transaction_ids` is given, only those transactions are considered.
- Produces: `PdfImport#apply_rules_to_imported_transactions!` (called at the end of `import!` for parsed imports only).

- [ ] **Step 1: Write the failing Rule test** (append to `test/models/rule_test.rb`)

```ruby
  test "apply can be limited to specific transactions" do
    inside = create_transaction(date: Date.current, account: @account, merchant: @whole_foods_merchant)
    outside = create_transaction(date: Date.current, account: @account, merchant: @whole_foods_merchant)

    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_merchant", operator: "=", value: @whole_foods_merchant.id) ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
    )

    rule.apply(transaction_ids: [ inside.transaction.id ])

    assert_equal @groceries_category, inside.reload.transaction.category
    assert_nil outside.reload.transaction.category
  end
```

- [ ] **Step 2: Write the failing PdfImport test** (append inside `PdfImportStatementParsingTest`, above `private`)

```ruby
  test "publishing a parsed import runs active rules on only its transactions" do
    account = accounts(:depository)
    category = @family.categories.create!(name: "Online shopping")
    Rule.create!(
      family: @family, resource_type: "transaction", active: true, effective_date: Date.new(2024, 1, 1),
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "SHOPEE") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: category.id) ]
    )
    unrelated = account.entries.create!(
      date: Date.new(2025, 1, 3), amount: 10, name: "SHOPEE old", currency: account.currency,
      entryable: Transaction.new
    )

    @import.apply_parse_result!(casa_result)
    @import.assign_account!(account)
    @import.reload.publish

    shopee = @import.entries.find_by(name: "FPX PAYMENT SHOPEE")
    assert_equal "complete", @import.reload.status
    assert_equal category, shopee.transaction.category
    assert_nil unrelated.reload.transaction.category
  end
```

- [ ] **Step 3: Run to verify they fail**

Run: `bin/rails test test/models/rule_test.rb test/models/pdf_import_statement_parsing_test.rb`
Expected: `unknown keyword: :transaction_ids`; category nil on the imported row.

- [ ] **Step 4: Implement Rule narrowing** (`app/models/rule.rb`)

Change the `apply` signature and the scope call:

```ruby
  def apply(ignore_attribute_locks: false, rule_run: nil, transaction_ids: nil)
    total_modified = 0
    total_async_jobs = 0
    has_async = false

    scope = matching_resources_scope(transaction_ids: transaction_ids)

    actions.each do |action|
      result = action.apply(scope, ignore_attribute_locks: ignore_attribute_locks, rule_run: rule_run)
```

(leave the rest of the method unchanged), and:

```ruby
    def matching_resources_scope(transaction_ids: nil)
      scope = registry.resource_scope
      # Fork: lets an import run rules on just the rows it created.
      scope = scope.where(id: transaction_ids) if transaction_ids

      # ... existing prepare/apply loops unchanged
```

- [ ] **Step 5: Implement the hook**

In `app/models/pdf_import/statement_parsing.rb` add the public method:

```ruby
  # Q9/Q18: the parser cannot categorise, so the family's own rules do it --
  # scoped to what this import created, so publishing never rewrites history.
  # A failing rule must not fail a publish whose data has already committed.
  def apply_rules_to_imported_transactions!
    transaction_ids = Transaction.joins(:entry).where(entries: { import_id: id }).pluck(:id)
    return if transaction_ids.empty?

    family.rules.where(active: true, resource_type: "transaction").find_each do |rule|
      rule.apply(transaction_ids: transaction_ids)
    rescue StandardError => e
      Rails.logger.error("PdfImport #{id}: rule #{rule.id} failed after publish: #{e.class}")
    end
  end
```

In `app/models/pdf_import.rb`, at the end of `import!` (after the `transaction do ... end` block, still inside the method):

```ruby
    apply_rules_to_imported_transactions! if parsed?
```

- [ ] **Step 6: Run tests**

Run: `bin/rails test test/models/rule_test.rb test/models/pdf_import_statement_parsing_test.rb test/models/pdf_import_test.rb test/models/pdf_import_reconciliation_test.rb`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add app/models/rule.rb app/models/pdf_import/statement_parsing.rb app/models/pdf_import.rb test/models/rule_test.rb test/models/pdf_import_statement_parsing_test.rb
git commit -m "feat(pdf-import): apply family rules to parsed imports after publish

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Calibrate against real statements (local-only)

**Files:**
- Create: `test/models/statement_parser/real_statements_test.rb`
- Possibly modify: regex constants in `maybank_casa.rb`, `maybank_credit_card.rb`, `touch_n_go.rb`, and the synthetic fixtures (shape only)

- [ ] **Step 1: Write the opt-in test**

`test/models/statement_parser/real_statements_test.rb`:

```ruby
require "test_helper"

# Local-only. Never commit real statements. Run with:
#   STATEMENT_DIR=~/statements STATEMENT_PASSWORD=... bin/rails test test/models/statement_parser/real_statements_test.rb
class StatementParser::RealStatementsTest < ActiveSupport::TestCase
  test "every real statement parses and reconciles" do
    dir = ENV["STATEMENT_DIR"]
    skip "set STATEMENT_DIR to run against real statements" if dir.blank?

    paths = Dir[File.join(File.expand_path(dir), "**/*.pdf")]
    assert paths.any?, "no PDFs under #{dir}"

    paths.each do |path|
      name = File.basename(path)
      result = StatementParser.parse(File.binread(path), password: ENV["STATEMENT_PASSWORD"].presence)

      assert result.transactions.any?, "#{name}: no transactions"
      assert result.transactions.all? { _1.name.present? }, "#{name}: blank transaction name"
      result.checks.each do |check|
        assert check["matched"], "#{name} (#{result.parser_key}): #{check['key']} printed #{check['printed']} parsed #{check['parsed']}"
      end
    end
  end
end
```

- [ ] **Step 2: Owner runs it**

Ask the owner to put several months of each statement type in `~/statements/` (outside the repo) and run:

```bash
STATEMENT_DIR=~/statements STATEMENT_PASSWORD='<password>' bin/rails test test/models/statement_parser/real_statements_test.rb
```

(Prefix with a space so zsh does not save it in history if `HIST_IGNORE_SPACE` is set, or leave `STATEMENT_PASSWORD` unset and use unencrypted copies.)

Expected first time: likely some failures. For each failure, dump that file (`bin/rails "statement_parser:dump[<path>]"`), find the line shape the regex misses, and fix the regex constant. After each fix, update the synthetic fixture to include the new shape (fake values) and add an assertion to that parser's test so the shape stays covered. Re-run both the parser test and this test until green.

- [ ] **Step 3: Commit (test + any regex/fixture fixes; never PDFs or dumps)**

```bash
git status --short   # confirm no .pdf/.txt from ~/statements is staged
git add test/models/statement_parser app/models/statement_parser test/fixtures/files/statement_parser
git commit -m "test(statement-parser): opt-in calibration against real statements

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Full suite, lint, own image

- [ ] **Step 1: Full checks**

```bash
bin/rails test
bin/rubocop -f github -a
bundle exec erb_lint ./app/**/*.erb -a
bin/brakeman --no-pager
```

Expected: all green. Fix anything introduced by this branch; report (don't fix) pre-existing upstream failures.

- [ ] **Step 2: Build your own image** (the published `ghcr.io/we-promise/sure:stable` will not contain this code)

```bash
docker build -t sure-kwgn:latest .
```

Then in your compose file replace `image: ghcr.io/we-promise/sure:stable` (both `web` and `worker` services) with `image: sure-kwgn:latest`, and make sure `PDF_IMPORT_AI` is unset or `false`, and that neither `OPENAI_ACCESS_TOKEN` nor `VECTOR_STORE_PROVIDER` is set if you want a no-LLM install.

- [ ] **Step 3: Account naming tip for matching**

`AccountStatement::AccountMatcher` scores institution name (+0.45) and last-4 in the account *name* (+0.25), and refuses to guess between ties. With three Maybank accounts, include the last 4 digits in each sure account name (e.g. "Maybank MAE 1234") so the picker pre-selects the right one.

- [ ] **Step 4: Push the branch to the fork**

`origin` is the owner's fork (`mirzanorazman/sure`); `upstream` is `we-promise/sure` (fetch-only in practice).

```bash
git push -u origin kwgn-parser
```

Later upstream updates: `git fetch upstream && git rebase upstream/main` on this branch.
