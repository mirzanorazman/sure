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
