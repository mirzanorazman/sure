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
