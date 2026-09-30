# Deterministic parsers for Malaysian e-statements (ported from kwgn). Nothing
# here talks to an LLM, an embeddings API or a vector store: the statement is
# read with pdf-reader and matched with regular expressions, in-process.
module StatementParser
  class Error < StandardError; end
  class PasswordRequired < Error; end
  class WrongPassword < Error; end
  class Unsupported < Error; end
  class Unreadable < Error; end
end
