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
