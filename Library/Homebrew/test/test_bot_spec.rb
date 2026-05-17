# typed: strict
# frozen_string_literal: true

require "dev-cmd/test-bot"

RSpec.describe Homebrew::TestBot do
  let(:klass) { Homebrew::TestBot }

  describe "::setup_github_actions_sandbox!" do
    around do |example|
      with_env(HOMEBREW_NO_SANDBOX_LINUX: nil) { example.run }
    end

    before do
      allow(GitHub::Actions).to receive(:env_set?).and_return(true)
      allow(Homebrew::EnvConfig).to receive(:sandbox_linux?).and_return(true)
    end

    it "configures the Linux sandbox for GitHub Actions" do
      expect(klass).to receive(:configure_sandbox!).and_return(true)

      klass.setup_github_actions_sandbox!
    end

    it "disables the Linux sandbox if GitHub Actions cannot configure it" do
      allow(klass).to receive(:configure_sandbox!).and_return(false)

      klass.setup_github_actions_sandbox!

      expect(ENV.fetch("HOMEBREW_NO_SANDBOX_LINUX")).to eq("1")
    end

    it "does nothing outside GitHub Actions" do
      allow(GitHub::Actions).to receive(:env_set?).and_return(false)
      expect(klass).not_to receive(:configure_sandbox!)

      klass.setup_github_actions_sandbox!
    end

    it "does nothing when the Linux sandbox is disabled" do
      allow(Homebrew::EnvConfig).to receive(:sandbox_linux?).and_return(false)
      expect(klass).not_to receive(:configure_sandbox!)

      klass.setup_github_actions_sandbox!
    end
  end
end
