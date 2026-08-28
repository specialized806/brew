# typed: strict
# frozen_string_literal: true

require "cmd/shared_examples/args_parse"
require "dev-cmd/style"

RSpec.describe Homebrew::DevCmd::StyleCmd do
  it_behaves_like "parseable arguments"

  it "checks a Formula and Cask", :cask, :integration_test do
    formula_file = setup_test_formula "testball"
    HOMEBREW_LIBRARY.mkpath
    FileUtils.ln_s HOMEBREW_LIBRARY_PATH.parent/".rubocop.yml", HOMEBREW_LIBRARY/".rubocop.yml"
    FileUtils.ln_s HOMEBREW_LIBRARY_PATH, HOMEBREW_LIBRARY/"Homebrew"

    begin
      expect do
        brew "style", "--only-cops=Layout/TrailingWhitespace", formula_file, cask_path("local-caffeine")
      end.to be_a_success
    ensure
      FileUtils.rm_f HOMEBREW_LIBRARY/".rubocop.yml"
      FileUtils.rm_f HOMEBREW_LIBRARY/"Homebrew"
    end
  end
end
