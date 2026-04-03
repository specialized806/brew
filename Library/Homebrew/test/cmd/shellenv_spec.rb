# typed: false
# frozen_string_literal: true

RSpec.describe "brew shellenv", type: :system do
  it "prints export statements including FPATH for zsh", :integration_test do
    expect { brew_sh "shellenv", "zsh" }
      .to output(/export FPATH/).to_stdout
      .and not_to_output.to_stderr
      .and be_a_success
  end
end
