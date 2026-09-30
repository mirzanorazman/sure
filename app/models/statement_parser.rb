# Deterministic parsers for Malaysian e-statements (ported from kwgn). Nothing
# here talks to an LLM, an embeddings API or a vector store: the statement is
# read with pdf-reader and matched with regular expressions, in-process.
module StatementParser
  class Error < StandardError; end
  class PasswordRequired < Error; end
  class WrongPassword < Error; end
  class Unsupported < Error; end
  class Unreadable < Error; end

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
end
