# typed: strict
# frozen_string_literal: true

require "cmd/shared_examples/args_parse"
require "dev-cmd/formula-analytics"
require "utils/analytics"

RSpec.describe Homebrew::DevCmd::FormulaAnalytics do
  it_behaves_like "parseable arguments"

  describe "#format_os_version_dimension" do
    it "preserves WSL in formatted Linux versions" do
      expect(described_class.new([]).format_os_version_dimension(
               "Ubuntu 24.04.3 LTS#{Utils::Analytics::WSL_SUFFIX}",
             )).to eq("Ubuntu 24.04 LTS#{Utils::Analytics::WSL_SUFFIX}")
    end
  end
end
