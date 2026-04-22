# typed: false
# frozen_string_literal: true

require "cmd/developer"
require "cmd/shared_examples/args_parse"

RSpec.describe Homebrew::Cmd::Developer do
  it_behaves_like "parseable arguments"

  it "prints that Developer mode is disabled by default", :integration_test do
    expect { brew "developer" }
      .to output(/Developer mode is disabled/).to_stdout
      .and not_to_output.to_stderr
      .and be_a_success
  end
end
