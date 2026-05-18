# typed: true
# frozen_string_literal: true

require "cmd/shared_examples/args_parse"
require "dev-cmd/tests"

RSpec.describe Homebrew::DevCmd::Tests do
  it_behaves_like "parseable arguments"

  describe "#check_test_environment!", :needs_linux do
    subject(:tests) { described_class.new([]) }

    before do
      require "extend/os/linux/dev-cmd/tests"
      require "sandbox"

      allow(GitHub::Actions).to receive(:env_set?).and_return(false)
    end

    it "does not require the Linux sandbox unless HOMEBREW_SANDBOX_LINUX is set" do
      allow(Sandbox).to receive(:available?).and_return(false)
      expect(Sandbox).not_to receive(:ensure_sandbox_installed!)
      expect(Sandbox).not_to receive(:configure!)

      with_env(HOMEBREW_SANDBOX_LINUX: nil) do
        expect { tests.send(:check_test_environment!) }.not_to raise_error
      end
    end

    it "raises when the requested Linux sandbox is unavailable" do
      allow(Sandbox).to receive_messages(available?:     false,
                                         failure_reason: "Bubblewrap is not working.")
      expect(Sandbox).to receive(:ensure_sandbox_installed!).with(install_from_tests: true)

      with_env(HOMEBREW_SANDBOX_LINUX: "1") do
        expect { tests.send(:check_test_environment!) }
          .to raise_error(UsageError, "Invalid usage: Bubblewrap is not working.")
      end
    end

    it "installs and probes sandbox availability when Linux sandboxing is enabled" do
      allow(Sandbox).to receive(:available?).and_return(true)
      expect(Sandbox).to receive(:ensure_sandbox_installed!).with(install_from_tests: true)

      with_env(HOMEBREW_SANDBOX_LINUX: "1") do
        expect { tests.send(:check_test_environment!) }.not_to raise_error
      end
    end

    it "configures the sandbox on GitHub Actions when Linux sandboxing is enabled" do
      allow(GitHub::Actions).to receive(:env_set?).and_return(true)
      allow(Sandbox).to receive(:available?).and_return(true)
      expect(Sandbox).to receive(:configure!)
      expect(Sandbox).not_to receive(:ensure_sandbox_installed!)

      with_env(HOMEBREW_SANDBOX_LINUX: "1") do
        expect { tests.send(:check_test_environment!) }.not_to raise_error
      end
    end
  end
end
