# Maybank savings/current and MAE statements. Port of kwgn's
# MAYBANK_CASA_AND_MAE extractor.
class StatementParser::MaybankCasa < StatementParser::Base
  FINGERPRINT = /BEGINNING BALANCE/
  # The label and the date are often on different lines; the Chinese label
  # (結單日期) is the one that shares a line with the date.
  STATEMENT_DATE = %r{(?:STATEMENT DATE|TARIKH PENYATA|結單日期)\D*(\d{2}/\d{2}/\d{2})}
  ANY_DATE = %r{(\d{2}/\d{2}/\d{2})}
  # "ACCOUNT   123456-789012" with "NUMBER" wrapped onto the next line, or
  # "戶號   :   123456-789012".
  ACCOUNT_NUMBER = /(?:ACCOUNT|戶號)\D*?(\d{6}-\d{6}|\d{12})|(\d{6}-\d{6}|\d{12})\s*ACCOUNT\s*NUMBER/
  OPENING = /BEGINNING BALANCE\s*([\d,]+\.\d{2})(DR)?/
  CLOSING = /ENDING BALANCE\s*:?\s*([\d,]+\.\d{2})(DR)?/
  TOTAL_DEBIT = /TOTAL DEBIT\s*:?\s*([\d,]+\.\d{2})/
  TOTAL_CREDIT = /TOTAL CREDIT\s*:?\s*([\d,]+\.\d{2})/
  TRANSACTION = %r{\A\s*(\d{2}/\d{2}(?:/\d{2})?)\s+(.+?)\s+([\d,]*\.\d{2})([+-])\s+[\d,]*\.\d{2}(?:DR)?\s*\z}
  # Lines that end a transaction's description even when indented like one.
  STOP = /BEGINNING BALANCE|ENDING BALANCE|TOTAL (?:DEBIT|CREDIT)|STATEMENT DATE|TARIKH PENYATA|ACCOUNT\s*NUMBER|NOMBOR AKAUN/
  # Repeated at the top of every page. A row cut by a page break carries on
  # under it, after the footer and the next page's header.
  TABLE_HEADER = /ENTRY DATE.*STATEMENT BALANCE/
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
        elsif line.match?(TABLE_HEADER)
          rows << current if current
          current = rows.pop
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
