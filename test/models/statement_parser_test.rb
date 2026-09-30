require "test_helper"

class StatementParserTest < ActiveSupport::TestCase
  def fixture_lines(name)
    file_fixture("statement_parser/#{name}.txt").read.lines.map(&:rstrip).reject(&:blank?)
  end

  test "dispatches to the parser whose fingerprint matches" do
    { "maybank_casa" => "maybank_casa", "maybank_credit_card" => "maybank_credit_card", "touch_n_go" => "touch_n_go" }.each do |fixture, key|
      StatementParser::TextExtractor.stubs(:lines).returns(fixture_lines(fixture))
      assert_equal key, StatementParser.parse("pdf-bytes").parser_key
    end
  end

  test "unrecognised statements are unsupported" do
    assert_raises(StatementParser::Unsupported) do
      StatementParser.parse(file_fixture("imports/sample_bank_statement.pdf").binread)
    end
  end

  test "passes the password through" do
    StatementParser::TextExtractor.expects(:lines).with("pdf-bytes", password: "pw").returns(fixture_lines("touch_n_go"))
    StatementParser.parse("pdf-bytes", password: "pw")
  end
end
