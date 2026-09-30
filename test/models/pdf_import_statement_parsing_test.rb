require "test_helper"

class PdfImportStatementParsingTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @import = PdfImport.create_from_prepared_upload!(family: @family, prepared_upload: prepared_upload, user: @user)
  end

  test "applying a result stores rows, statement metadata and checks without touching AI state" do
    @import.apply_parse_result!(casa_result)
    @import.reload

    assert @import.parsed?
    assert @import.processed?
    assert_nil @import.ai_summary
    assert_equal "bank_statement", @import.document_type
    assert_equal "pending", @import.status
    assert_equal 2, @import.rows_count
    assert @import.configured?
    assert_equal [ "-150.0", "2500.0" ], @import.rows.order(:source_row_number).pluck(:amount)
    assert_equal "FPX PAYMENT SHOPEE", @import.rows.order(:source_row_number).first.name
    assert_not @import.statement_checks_mismatched?

    statement = @import.account_statement
    assert_equal "9012", statement.account_last4_hint
    assert_equal "Maybank", statement.institution_name_hint
    assert_equal Date.new(2025, 1, 1), statement.period_start_on
    assert_equal Date.new(2025, 1, 31), statement.period_end_on
    assert_equal BigDecimal("3350"), statement.closing_balance.to_d
  end

  test "mismatched printed totals are flagged" do
    @import.apply_parse_result!(casa_result(printed_total_debit: BigDecimal("999")))
    assert @import.reload.statement_checks_mismatched?
  end

  test "an empty statement completes" do
    @import.apply_parse_result!(casa_result(transactions: [], printed_total_credit: nil, printed_total_debit: nil, closing_balance: nil))
    assert_equal "complete", @import.reload.status
  end

  test "password-required state" do
    @import.mark_password_required!
    assert @import.reload.password_required?
    assert_not @import.parsed?
  end

  test "parse_statement! with the right password applies the result" do
    @import.mark_password_required!
    StatementParser.expects(:parse).with(@import.pdf_file_content, password: "pw").returns(casa_result)

    assert_equal :parsed, @import.parse_statement!(password: "pw")
    assert @import.reload.parsed?
  end

  test "parse_statement! with a wrong password changes nothing" do
    @import.mark_password_required!
    StatementParser.stubs(:parse).raises(StatementParser::WrongPassword)

    assert_equal :wrong_password, @import.parse_statement!(password: "nope")
    assert @import.reload.password_required?
  end

  test "parse_statement! does not re-parse a parsed import" do
    @import.apply_parse_result!(casa_result)
    StatementParser.expects(:parse).never

    assert_equal :parsed, @import.parse_statement!(password: nil)
  end

  test "re-uploading the same file reuses the parsed import" do
    @import.apply_parse_result!(casa_result)

    again = PdfImport.create_from_prepared_upload!(family: @family, prepared_upload: prepared_upload, user: @user)

    assert_equal @import, again
    assert again.parsed?
    assert_equal 2, again.rows_count
  end

  test "discarding an unparsed import removes its unlinked statement" do
    statement = @import.account_statement

    assert_difference [ "Import.count", "AccountStatement.count" ], -1 do
      @import.discard_unparsed!
    end
    assert_not AccountStatement.exists?(statement.id)
  end

  test "the AI path is off unless PDF_IMPORT_AI is set" do
    ClimateControl.modify(PDF_IMPORT_AI: nil) { assert_not PdfImport.ai_processing_enabled? }
    ClimateControl.modify(PDF_IMPORT_AI: "true") { assert PdfImport.ai_processing_enabled? }
  end

  test "publishing a parsed import runs active rules on only its transactions" do
    account = accounts(:depository)
    category = @family.categories.create!(name: "Online shopping")
    Rule.create!(
      family: @family, resource_type: "transaction", active: true, effective_date: Date.new(2024, 1, 1),
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "SHOPEE") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: category.id) ]
    )
    unrelated = account.entries.create!(
      date: Date.new(2025, 1, 3), amount: 10, name: "SHOPEE old", currency: account.currency,
      entryable: Transaction.new
    )

    @import.apply_parse_result!(casa_result)
    @import.assign_account!(account)
    @import.reload.publish

    shopee = @import.entries.find_by(name: "FPX PAYMENT SHOPEE")
    assert_equal "complete", @import.reload.status
    assert_equal category, shopee.transaction.category
    assert_nil unrelated.reload.transaction.category
  end

  test "a failing rule does not fail the publish and is recorded for support" do
    Rule.create!(
      family: @family, resource_type: "transaction", active: true, effective_date: Date.new(2024, 1, 1),
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "SHOPEE") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @family.categories.create!(name: "Shops").id) ]
    )
    Rule.any_instance.stubs(:apply).raises(StandardError, "boom")

    @import.apply_parse_result!(casa_result)
    @import.assign_account!(accounts(:depository))

    assert_difference "DebugLogEntry.count", 1 do
      @import.reload.publish
    end
    assert_equal "complete", @import.reload.status
  end

  private
    def prepared_upload
      AccountStatement.prepare_upload!(
        uploaded_file(
          filename: "maybank.pdf",
          content_type: "application/pdf",
          content: file_fixture("imports/sample_bank_statement.pdf").binread
        )
      )
    end

    def casa_result(**overrides)
      StatementParser::Result.new(**{
        parser_key: "maybank_casa", document_type: "bank_statement", institution_name: "Maybank",
        account_last4: "9012", currency: "MYR", liability: false,
        period_start_on: Date.new(2025, 1, 1), period_end_on: Date.new(2025, 1, 31),
        opening_balance: BigDecimal("1000"), closing_balance: BigDecimal("3350"),
        printed_total_credit: BigDecimal("2500"), printed_total_debit: BigDecimal("150"),
        transactions: [
          StatementParser::Transaction.new(date: Date.new(2025, 1, 2), amount: BigDecimal("-150"), name: "FPX PAYMENT SHOPEE", notes: nil),
          StatementParser::Transaction.new(date: Date.new(2025, 1, 15), amount: BigDecimal("2500"), name: "SALARY", notes: nil)
        ]
      }.merge(overrides))
    end
end
