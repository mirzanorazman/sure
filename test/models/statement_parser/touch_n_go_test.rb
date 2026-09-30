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
