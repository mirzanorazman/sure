# Maybank 2 credit card statements. Port of kwgn's MAYBANK_2_CC extractor.
# One statement can carry several cards (e.g. the Mastercard and the Amex),
# each with its own balance and totals block; figures are summed across cards.
class StatementParser::MaybankCreditCard < StatementParser::Base
  FINGERPRINT = /PENYATA AKAUN KAD KREDIT/
  STATEMENT_DATE = /\b(\d{2})\s(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)\s(\d{2})\b/
  CARD_NUMBER = /\b\d{4}[ -]?(?:\d{4}|[X*]{4})[ -]?(?:\d{4}|[X*]{4})[ -]?(\d{4})\b/
  OPENING = /YOUR PREVIOUS STATEMENT BALANCE\s*([\d,]+\.\d{2})(CR)?/
  CLOSING = %r{SUB TOTAL/JUMLAH\s*([\d,]+\.\d{2})(CR)?}
  # The "(JUMLAH KREDIT)" label usually wraps onto the line below the amount.
  TOTAL_CREDIT = /TOTAL CREDIT THIS MONTH\s*(?:\(JUMLAH KREDIT\))?\s*([\d,]+\.\d{2})/
  TOTAL_DEBIT = /TOTAL DEBIT THIS MONTH\s*(?:\(JUMLAH DEBIT\))?\s*([\d,]+\.\d{2})/
  TRANSACTION = %r{\A\s*(\d{2})/(\d{2})\s+\d{2}/\d{2}\s+(.+?)\s+([\d,]+\.\d{2})(CR)?\s*\z}
  # An FPX reference printed alone under its row (possibly after a page break).
  REFERENCE = /\A\s+(\d{10,})\z/

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
      printed_total_credit: summed_balance(TOTAL_CREDIT),
      printed_total_debit: summed_balance(TOTAL_DEBIT),
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
      rows = []

      lines.each do |line|
        if (match = line.match(TRANSACTION))
          amount = money(match[4])
          rows << {
            date: date_in_statement_year(match[1].to_i, match[2].to_i, statement_date),
            amount: match[5] ? amount : -amount,
            name: match[3].squish,
            references: []
          }
        elsif rows.any? && (reference = line.match(REFERENCE))
          rows.last[:references] << reference[1]
        end
      end

      rows.map do |row|
        StatementParser::Transaction.new(date: row[:date], amount: row[:amount], name: row[:name], notes: row[:references].join(" ").presence)
      end
    end
end
