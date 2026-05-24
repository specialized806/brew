# typed: false
# frozen_string_literal: true

require "cmd/bundle"
require "cmd/shared_examples/args_parse"
require "commands"

RSpec.describe Homebrew::Cmd::Bundle do
  let(:klass) { Homebrew::Cmd::Bundle }

  it_behaves_like "parseable arguments"

  it "handles default install subcommand options", :aggregate_failures do
    with_env("HOMEBREW_BUNDLE_INSTALL_CLEANUP" => nil) do
      expect(klass.new([]).args.subcommand).to eq("install")
      expect(klass.new(%w[--cleanup --zap]).args.subcommand).to eq("install")
      expect { klass.new(%w[--zap]) }
        .to raise_error(UsageError, /`--zap` cannot be passed without `--cleanup`/)
    end
  end

  it "rejects install-only options for exec" do
    expect { klass.new(%w[exec --jobs=1 true]) }
      .to raise_error(UsageError, /`exec` subcommand does not accept the `--jobs` flag/)
  end

  it "treats upgrade as install --upgrade", :aggregate_failures do
    with_env("HOMEBREW_BUNDLE_NO_UPGRADE" => "1") do
      args = klass.new(%w[upgrade -fq]).args
      context = klass.context(args, extensions: klass::BUNDLE_EXTENSIONS)

      expect(args.subcommand).to eq("install")
      expect(args.upgrade?).to be(true)
      expect(args.force?).to be(true)
      expect(args.quiet?).to be(true)
      expect(context.subcommand).to eq("install")
      expect(context.no_upgrade).to be(false)
    end
  end

  it "accepts global flags on subcommands that do not re-declare them", :aggregate_failures do
    expect(klass.new(%w[cleanup --verbose]).args.verbose?).to be(true)
    expect(klass.new(%w[cleanup -v]).args.verbose?).to be(true)
    expect(klass.new(%w[dump --verbose]).args.subcommand).to eq("dump")
    expect(klass.new(%w[list --verbose]).args.subcommand).to eq("list")
  end

  it "uses subcommand-specific option descriptions", :aggregate_failures do
    subcommand_options = ->(subcommand) { Commands.command_options("bundle", subcommand:).to_h }

    expect(subcommand_options.call("list")["--vscode"]).to eq("List VSCode (and forks/variants) extensions.")
    expect(subcommand_options.call("dump")["--vscode"]).to eq("Dump VSCode (and forks/variants) extensions.")
    expect(subcommand_options.call("cleanup")["--vscode"]).to eq("Clean up VSCode (and forks/variants) extensions.")
    expect(subcommand_options.call("cleanup")["--all"]).to eq("Clean up all supported dependencies.")
    expect(subcommand_options.call("add")["--vscode"])
      .to eq("Add entries for VSCode (and forks/variants) extensions.")
    expect(subcommand_options.call("remove")["--vscode"])
      .to eq("Remove entries for VSCode (and forks/variants) extensions.")
    expect(subcommand_options.call("upgrade")["--force"]).to eq("Run with `--force`/`--overwrite`.")
  end

  it "uses subcommand-specific descriptions in help output", :aggregate_failures do
    help_text = klass.parser.generate_help_text(remaining_args: ["list"])

    expect(help_text).to include("List VSCode (and forks/variants) extensions.")
    expect(help_text).not_to include("Clean up VSCode (and forks/variants) extensions.")
  end

  [
    ["exec", ["exec", "--check", "/usr/bin/true"], "/usr/bin/true"],
    ["sh", ["sh", "--check"], "sh"],
    ["env", ["env", "--check"], "env"],
  ].each do |subcommand, args, command|
    it "passes --check through to #{subcommand}" do
      with_env("HOMEBREW_BUNDLE_NO_SECRETS" => nil) do
        expect(Homebrew::Cmd::Bundle::ExecSubcommand).to receive(:run_external_command)
          .with(
            command,
            global:     false,
            file:       nil,
            subcommand:,
            services:   false,
            check:      true,
            no_secrets: false,
          )

        klass.new(args).run
      end
    end
  end

  it "passes HOMEBREW_BUNDLE_CHECK through to exec" do
    with_env("HOMEBREW_BUNDLE_CHECK" => "1", "HOMEBREW_BUNDLE_NO_SECRETS" => nil) do
      expect(Homebrew::Cmd::Bundle::ExecSubcommand).to receive(:run_external_command)
        .with(
          "/usr/bin/true",
          global:     false,
          file:       nil,
          subcommand: "exec",
          services:   false,
          check:      true,
          no_secrets: false,
        )

      klass.new(["exec", "/usr/bin/true"]).run
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
