# frozen_string_literal: true

require "cmd/missing"
require "cmd/shared_examples/args_parse"

RSpec.describe Homebrew::Cmd::Missing do
  it_behaves_like "parseable arguments"

  it "does not report missing deps when tab has no runtime dependency data", :integration_test, :no_api do
    setup_test_formula "foo"
    setup_test_formula "bar"

    (HOMEBREW_CELLAR/"bar/1.0").mkpath

    expect { brew "missing" }
      .to be_a_success
      .and not_to_output.to_stdout
      .and not_to_output.to_stderr
  end
end
