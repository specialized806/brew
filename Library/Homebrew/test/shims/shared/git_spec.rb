# typed: true
# frozen_string_literal: true

require "fileutils"
require "system_command"

RSpec.describe "shims/shared/git", type: :system do
  let(:tool) { "homebrew-shim-test" }

  it "does not exec itself from outside shims/shared" do
    shims_dir = mktmpdir/"Library/Homebrew/shims/super"
    shims_dir.mkpath
    FileUtils.cp HOMEBREW_SHIMS_PATH/"shared/git", shims_dir/tool
    ENV["PATH"] = PATH.new(ENV.fetch("PATH")).prepend(shims_dir).to_s

    expect(SystemCommand.run(shims_dir/tool, timeout: 10).stderr).to eq("You must: brew install #{tool}\n")
  end

  it "does not exec the same shim from another Homebrew checkout" do
    shims_dirs = %w[a b].map do |checkout|
      shims_dir = mktmpdir/checkout/"Library/Homebrew/shims/shared"
      shims_dir.mkpath
      FileUtils.cp HOMEBREW_SHIMS_PATH/"shared/git", shims_dir
      FileUtils.ln_s "git", shims_dir/tool
      shims_dir
    end
    ENV["PATH"] = PATH.new(ENV.fetch("PATH")).prepend(*shims_dirs).to_s

    expect(SystemCommand.run(shims_dirs.fetch(0)/tool, timeout: 10).stderr)
      .to eq("You must: brew install #{tool}\n")
  end
end
