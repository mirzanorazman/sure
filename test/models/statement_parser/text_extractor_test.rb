require "test_helper"

class StatementParser::TextExtractorTest < ActiveSupport::TestCase
  setup do
    @plain = file_fixture("imports/sample_bank_statement.pdf").binread
    @encrypted = file_fixture("imports/sample_bank_statement_encrypted.pdf").binread
  end

  test "extracts non-blank, right-stripped lines" do
    lines = StatementParser::TextExtractor.lines(@plain)

    assert lines.any?
    assert lines.none?(&:blank?)
    assert lines.none? { |line| line.end_with?(" ") }
  end

  test "asks for a password when the PDF is protected" do
    assert_raises(StatementParser::PasswordRequired) do
      StatementParser::TextExtractor.lines(@encrypted)
    end
  end

  test "rejects a wrong password without echoing it" do
    error = assert_raises(StatementParser::WrongPassword) do
      StatementParser::TextExtractor.lines(@encrypted, password: "hunter2-secret")
    end

    assert_not_includes error.message, "hunter2-secret"
    assert_nil error.cause
  end

  test "decrypts with the right password" do
    assert_equal StatementParser::TextExtractor.lines(@plain),
                 StatementParser::TextExtractor.lines(@encrypted, password: "test1234")
  end

  test "reports content that is not a readable PDF" do
    assert_raises(StatementParser::Unreadable) do
      StatementParser::TextExtractor.lines("%PDF-1.4\nnot really a pdf")
    end
  end
end
