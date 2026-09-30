# Fork: receives the password for a protected statement. The password is used
# for this request's parse only -- never stored, queued or echoed back.
class Import::PdfPasswordsController < ApplicationController
  before_action :set_import

  def update
    case @import.parse_statement!(password: params[:password].to_s)
    when :parsed
      redirect_to import_path(@import), notice: t("imports.pdf_password.parsed")
    when :wrong_password, :password_required
      redirect_to import_path(@import), alert: t("imports.pdf_password.wrong_password")
    else
      @import.discard_unparsed!
      redirect_to new_import_path, alert: t("imports.create.pdf_unsupported")
    end
  end

  private
    def set_import
      @import = Current.family.imports.where(type: "PdfImport").find(params[:import_id])
      statement = @import.account_statement
      raise ActiveRecord::RecordNotFound if statement.present? && !statement.manageable_by?(Current.user)
    end
end
