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
