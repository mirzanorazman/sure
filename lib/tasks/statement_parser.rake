namespace :statement_parser do
  desc "Print the text lines the statement parsers see for a PDF (for writing fixtures). Prompts for a password if needed."
  task :dump, [ :path ] => :environment do |_task, args|
    require "io/console"

    content = File.binread(args.fetch(:path))
    lines =
      begin
        StatementParser::TextExtractor.lines(content)
      rescue StatementParser::PasswordRequired
        StatementParser::TextExtractor.lines(content, password: $stdin.getpass("PDF password: "))
      end

    puts lines
  end
end
