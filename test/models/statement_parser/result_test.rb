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
