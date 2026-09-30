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
    assert_equal BigDecimal("1200"), @result.printed_total_credit
    assert_equal BigDecimal("109.30"), @result.printed_total_debit
  end

  test "a December line on a January statement is dated last year" do
    assert_equal Date.new(2024, 12, 28), @result.transactions.first.date
    assert_equal Date.new(2025, 1, 2), @result.transactions.second.date
  end

  test "charges are outflows and CR lines are inflows" do
    assert_equal [ BigDecimal("-85.90"), BigDecimal("1200"), BigDecimal("-23.40") ], @result.transactions.map(&:amount)
    assert_equal "GRAB* A-1234 AP PETALING JAYA MY", @result.transactions.last.name
  end

  test "a reference printed under a row, even after a page break, becomes its notes" do
    assert_equal "2512280000000001", @result.transactions.first.notes
    assert_nil @result.transactions.last.notes
  end

  test "the fixture reconciles" do
    assert @result.checks.all? { _1["matched"] }
  end

  test "a credit balance is negative" do
    lines = @lines.map { _1.sub(/SUB TOTAL\/JUMLAH\s+109\.30/, "SUB TOTAL/JUMLAH   15.00CR") }
    assert_equal BigDecimal("-15"), StatementParser::MaybankCreditCard.new(lines).parse.closing_balance
  end

  test "a statement with a second card sums both cards' figures" do
    supplementary = <<~TEXT.lines.map(&:rstrip)
                                     MAYBANK 2 GOLD AMEX    :  3791 123456 78901
                                     YOUR PREVIOUS STATEMENT BALANCE                                                       0.00
          10/01           09/01      IKEA-CHERAS       AP                                 MY                              50.00
          20/01           20/01      CASH REBATE                                                                           5.00CR
                                     TOTAL CREDIT THIS MONTH                              5.00
                                     (JUMLAH KREDIT)
                                     TOTAL DEBIT THIS MONTH                               50.00
                                     (JUMLAH DEBIT)
                                                                                             SUB TOTAL/JUMLAH             45.00
    TEXT
    result = StatementParser::MaybankCreditCard.new(@lines + supplementary).parse

    assert_equal 5, result.transactions.size
    assert_equal "4321", result.account_last4
    assert_equal BigDecimal("1205"), result.printed_total_credit
    assert_equal BigDecimal("159.30"), result.printed_total_debit
    assert_equal BigDecimal("154.30"), result.closing_balance
    assert result.checks.all? { _1["matched"] }
  end
end
