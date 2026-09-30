require "test_helper"

class Import::PdfPasswordsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @import = PdfImport.create_from_prepared_upload!(
      family: @user.family,
      prepared_upload: AccountStatement.prepare_upload!(
        uploaded_file(filename: "locked.pdf", content_type: "application/pdf",
                      content: file_fixture("imports/sample_bank_statement_encrypted.pdf").binread)
      ),
      user: @user
    )
    @import.mark_password_required!
  end

  test "right password parses the statement" do
    PdfImport.any_instance.expects(:parse_statement!).with(password: "test1234").returns(:parsed)

    patch import_pdf_password_url(@import), params: { password: "test1234" }

    assert_redirected_to import_url(@import)
    assert_equal I18n.t("imports.pdf_password.parsed"), flash[:notice]
  end

  test "wrong password asks again and never echoes it" do
    patch import_pdf_password_url(@import), params: { password: "not-it-123" }

    assert_redirected_to import_url(@import)
    assert_equal I18n.t("imports.pdf_password.wrong_password"), flash[:alert]
    assert_not_includes flash[:alert], "not-it-123"
    assert @import.reload.password_required?
  end

  test "a decrypted but unsupported statement is discarded" do
    # sample_bank_statement is not a Malaysian statement, so the real parser rejects it.
    assert_difference "PdfImport.count", -1 do
      patch import_pdf_password_url(@import), params: { password: "test1234" }
    end

    assert_redirected_to new_import_url
    assert_equal I18n.t("imports.create.pdf_unsupported"), flash[:alert]
  end

  test "the password is filtered from logs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal "[FILTERED]", filter.filter("password" => "test1234")["password"]
  end
end
