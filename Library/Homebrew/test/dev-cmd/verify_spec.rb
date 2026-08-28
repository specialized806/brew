# typed: strict
# frozen_string_literal: true

require "cmd/shared_examples/args_parse"
require "dev-cmd/verify"

RSpec.describe Homebrew::DevCmd::Verify do
  it_behaves_like "parseable arguments"

  it "checks whether a Formula has a bottle to verify", :integration_test do
    setup_test_formula "testball"

    expect { brew "verify", "testball" }
      .to output(/Bottle for tag .* is unavailable\./).to_stderr
      .and be_a_success
  end
end
