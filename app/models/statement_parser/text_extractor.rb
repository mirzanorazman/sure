class StatementParser::TextExtractor
  # pdf-reader's layout text keeps column spacing, which the parsers rely on to
  # tell a description continuation line from a new row.
  def self.lines(content, password: nil)
    reader = PDF::Reader.new(StringIO.new(content), password: password.presence)
    reader.pages.flat_map { |page| page.text.lines }.map(&:rstrip).reject(&:blank?)
  rescue PDF::Reader::EncryptedPDFError
    # pdf-reader's message is "Invalid password (<the password>)". Raise a fresh
    # error with no cause so the password cannot reach logs or Sentry.
    error = password.present? ? StatementParser::WrongPassword : StatementParser::PasswordRequired
    raise error, cause: nil
  rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError
    raise StatementParser::Unreadable, cause: nil
  end
end
