# typed: true
# frozen_string_literal: true

require "utils/editor"

RSpec.describe Utils::Editor do
  describe ".command" do
    it "uses the configured editor" do
      ENV["HOMEBREW_EDITOR"] = "vemate -w"

      expect(described_class.command).to eq("vemate -w")
    end
  end
end
