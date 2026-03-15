# typed: strict
# frozen_string_literal: true

require "bundle/extensions/extension"

extensions_dir = File.join(__dir__, "extensions")
Dir.glob(File.join(extensions_dir, "*.rb")).each do |file|
  basename = File.basename(file, ".rb")
  next if basename == "extension"

  require "bundle/extensions/#{basename}"
end
