# typed: false
# frozen_string_literal: true

require "cmd/bundle"
require "cmd/shared_examples/args_parse"

RSpec.describe Homebrew::Cmd::Bundle do
  it_behaves_like "parseable arguments"

  [
    ["exec", ["exec", "--check", "/usr/bin/true"], "/usr/bin/true"],
    ["sh", ["sh", "--check"], "sh"],
    ["env", ["env", "--check"], "env"],
  ].each do |subcommand, args, command|
    it "passes --check through to #{subcommand}" do
      require "bundle/commands/exec"

      with_env("HOMEBREW_BUNDLE_NO_SECRETS" => nil) do
        expect(Homebrew::Bundle::Commands::Exec).to receive(:run)
          .with(
            command,
            global:     false,
            file:       nil,
            subcommand:,
            services:   false,
            check:      true,
            no_secrets: false,
          )

        described_class.new(args).run
      end
    end
  end

  it "passes HOMEBREW_BUNDLE_CHECK through to exec" do
    require "bundle/commands/exec"

    with_env("HOMEBREW_BUNDLE_CHECK" => "1", "HOMEBREW_BUNDLE_NO_SECRETS" => nil) do
      expect(Homebrew::Bundle::Commands::Exec).to receive(:run)
        .with(
          "/usr/bin/true",
          global:     false,
          file:       nil,
          subcommand: "exec",
          services:   false,
          check:      true,
          no_secrets: false,
        )

      described_class.new(["exec", "/usr/bin/true"]).run
    end
  end

  it "checks if a Brewfile's dependencies are satisfied", :integration_test do
    HOMEBREW_REPOSITORY.cd do
      system "git", "init"
      system "git", "commit", "--allow-empty", "-m", "This is a test commit"
    end

    mktmpdir do |path|
      FileUtils.touch "#{path}/Brewfile"
      path.cd do
        expect { brew "bundle", "check" }
          .to output("The Brewfile's dependencies are satisfied.\n").to_stdout
          .and not_to_output.to_stderr
          .and be_a_success
      end
    end
  end
end
