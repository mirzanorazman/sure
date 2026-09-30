# Fork-only: deterministic statement parsing for PdfImport (see
# StatementParser). Feeds the same extracted_data -> rows pipeline the AI path
# uses, but runs in-process and never reaches ProcessPdfJob, an LLM provider or
# the vector store.
module PdfImport::StatementParsing
  extend ActiveSupport::Concern

  class_methods do
    # Upstream's AI extraction stays in the code for cheap rebases, but is only
    # reachable when explicitly switched on.
    def ai_processing_enabled?
      ActiveModel::Type::Boolean.new.cast(ENV.fetch("PDF_IMPORT_AI", "false")) || false
    end
  end

  def parsed?
    extracted_data.is_a?(Hash) && extracted_data["parser"].present?
  end

  def password_required?
    extracted_data.is_a?(Hash) && extracted_data["parse_status"] == "password_required"
  end

  def processed?
    ai_processed? || parsed?
  end

  def statement_checks
    parsed? ? Array(extracted_data["checks"]) : []
  end

  def statement_checks_mismatched?
    statement_checks.any? { |check| !check["matched"] }
  end

  # The password is used for this call only and never stored.
  def parse_statement!(password: nil)
    return :parsed if parsed?

    apply_parse_result!(StatementParser.parse(pdf_file_content, password: password))
    :parsed
  rescue StatementParser::WrongPassword
    :wrong_password
  rescue StatementParser::PasswordRequired
    :password_required
  rescue StatementParser::Unsupported, StatementParser::Unreadable
    :unsupported
  end

  def apply_parse_result!(result)
    transaction do
      update!(
        document_type: result.document_type,
        extracted_data: {
          "parser" => result.parser_key,
          "transactions" => result.transactions.map { |txn| serialize_transaction(txn) },
          "checks" => result.checks
        }
      )
      apply_statement_metadata!(result)
      generate_rows_from_extracted_data
      sync_mappings
      update!(status: rows_count.positive? ? :pending : :complete)
    end
  end

  def mark_password_required!
    update!(status: :pending, extracted_data: { "parse_status" => "password_required" })
  end

  # For an upload that turned out not to be a supported statement once
  # decrypted: nothing was extracted, so nothing is worth keeping.
  def discard_unparsed!
    statement = account_statement
    destroy!
    statement.destroy! if statement && statement.account_id.nil? && statement.pdf_imports.reload.none?
  end

  # Q9/Q18: the parser cannot categorise, so the family's own rules do it --
  # scoped to what this import created, so publishing never rewrites history.
  # A failing rule must not fail a publish whose data has already committed.
  def apply_rules_to_imported_transactions!
    transaction_ids = Transaction.joins(:entry).where(entries: { import_id: id }).pluck(:id)
    return if transaction_ids.empty?

    family.rules.where(active: true, resource_type: "transaction").find_each do |rule|
      rule.apply(transaction_ids: transaction_ids)
    rescue StandardError => e
      DebugLogEntry.capture(
        category: "imports",
        level: "error",
        message: "Rule failed after publishing a parsed statement: #{e.class}",
        source: self.class.name,
        family: family,
        metadata: { record_type: self.class.name, record_id: id, rule_id: rule.id, error_class: e.class.name }
      )
    end
  end

  private
    def serialize_transaction(txn)
      {
        "date" => txn.date.iso8601,
        "amount" => txn.amount.to_s("F"),
        "name" => txn.name,
        "notes" => txn.notes.to_s,
        "category" => ""
      }
    end

    def apply_statement_metadata!(result)
      statement = account_statement
      return unless statement

      statement.assign_attributes(
        institution_name_hint: result.institution_name,
        account_last4_hint: result.account_last4,
        currency: result.currency,
        period_start_on: result.period_start_on,
        period_end_on: result.period_end_on,
        opening_balance: result.opening_balance,
        closing_balance: result.closing_balance
      )
      statement.assign_account_match if statement.account_id.nil?
      statement.save!
    end
end
