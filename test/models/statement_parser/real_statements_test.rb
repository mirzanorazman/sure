require "test_helper"

# Local-only. Never commit real statements. Run with:
#   STATEMENT_DIR=~/statements STATEMENT_PASSWORD=... bin/rails test test/models/statement_parser/real_statements_test.rb
class StatementParser::RealStatementsTest < ActiveSupport::TestCase
  test "every real statement parses and reconciles" do
    dir = ENV["STATEMENT_DIR"]
    skip "set STATEMENT_DIR to run against real statements" if dir.blank?

    paths = Dir[File.join(File.expand_path(dir), "**/*.pdf")]
    assert paths.any?, "no PDFs under #{dir}"

    paths.each do |path|
      name = File.basename(path)
      result = StatementParser.parse(File.binread(path), password: ENV["STATEMENT_PASSWORD"].presence)

      assert result.transactions.any?, "#{name}: no transactions"
      assert result.transactions.all? { _1.name.present? }, "#{name}: blank transaction name"
      result.checks.each do |check|
        assert check["matched"], "#{name} (#{result.parser_key}): #{check['key']} printed #{check['printed']} parsed #{check['parsed']}"
      end
    end
  end
end
