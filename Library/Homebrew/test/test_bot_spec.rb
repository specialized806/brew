# typed: strict
# frozen_string_literal: true

require "dev-cmd/test-bot"

RSpec.describe Homebrew::TestBot do
  sig { returns(T.class_of(Homebrew::TestBot)) }
  let(:klass) { Homebrew::TestBot }

  describe "::run!" do
    it "trusts a third-party tap before running test-bot" do
      tap = Tap.fetch("thirdparty", "foo")
      tap.path.mkpath
      args = double(
        cleanup?:       false,
        local?:         false,
        tap:            tap.name,
        only_formulae?: false,
        git_name:       nil,
        git_email:      nil,
      )

      allow(klass).to receive(:setup_github_actions_sandbox!)
      allow(Utils).to receive(:safe_popen_read).and_return("revision")
      allow(Homebrew::TestBot::TestRunner).to receive(:run!).and_return(true)

      expect { klass.run!(args) }.to output(%r{==> Trusted tap: thirdparty/foo}).to_stdout
      expect(Homebrew::Trust.trusted?(:tap, "thirdparty/foo")).to be(true)
    ensure
      Homebrew::Trust.clear!(:tap)
      FileUtils.rm_rf HOMEBREW_TAP_DIRECTORY/"thirdparty"
    end
  end

  describe "::setup_github_actions_sandbox!" do
    around do |example|
      with_env(HOMEBREW_NO_SANDBOX_LINUX: nil) { example.run }
    end

    before do
      allow(GitHub::Actions).to receive(:env_set?).and_return(true)
      allow(Homebrew::EnvConfig).to receive(:sandbox_linux?).and_return(true)
    end

    it "enables the Linux sandbox for GitHub Actions developers" do
      allow(Homebrew::EnvConfig).to receive(:sandbox_linux?).and_call_original
      expect(klass).to receive(:configure_sandbox!).and_return(true)

      with_env(HOMEBREW_DEVELOPER: "1", HOMEBREW_SANDBOX_LINUX: nil) do
        klass.setup_github_actions_sandbox!
      end
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
