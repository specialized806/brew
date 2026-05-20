# typed: false
# frozen_string_literal: true

require "cmd/list"
require "cmd/shared_examples/args_parse"

RSpec.describe Homebrew::Cmd::List do
  let(:formulae) { %w[bar foo qux] }

  def list_versions_json(formulae: [], casks: [])
    formulae = formulae.map do |f|
      f.merge(
        linked_version:    f.fetch(:linked_version, nil),
        optlinked_version: f.fetch(:optlinked_version, nil),
        pinned_version:    f.fetch(:pinned_version, nil),
      )
    end
    casks = casks.map do |c|
      c.merge(
        pinned_version: c.fetch(:pinned_version, nil),
      )
    end
    "#{JSON.generate({ formulae:, casks: })}\n"
  end

  def install_formula_version(name, version)
    (HOMEBREW_CELLAR/name/version/"somedir").mkpath
  end

  def install_cask(token)
    Cask::CaskLoader.load(token).tap { |cask| InstallHelper.stub_cask_installation(cask) }
  end

  def brew_sh_list(*args)
    env = args.last.is_a?(Hash) ? args.pop : {}
    stdout, stderr, status = Open3.capture3(
      {
        "HOMEBREW_CASKROOM" => Cask::Caskroom.path.to_s,
        "HOMEBREW_CELLAR"   => HOMEBREW_CELLAR.to_s,
        "HOMEBREW_LIBRARY"  => HOMEBREW_LIBRARY_PATH.to_s,
        "HOMEBREW_PREFIX"   => HOMEBREW_PREFIX.to_s,
      }.merge(env),
      "/bin/bash", "-c", 'source "$1"; shift; homebrew-list "$@"',
      "bash", (HOMEBREW_LIBRARY_PATH/"list.sh").to_s, "list", *args
    )
    $stdout.print stdout
    $stderr.print stderr
    status
  end

  it_behaves_like "parseable arguments"

  it "prints all installed formulae", :integration_test do
    formulae.each do |f|
      (HOMEBREW_CELLAR/f/"1.0/somedir").mkpath
    end

    expect { brew "list", "--formula" }
      .to output("#{formulae.join("\n")}\n").to_stdout
      .and not_to_output.to_stderr
      .and be_a_success
  end

  it "prints all installed formulae and casks", :integration_test do
    expect { brew_sh "list" }
      .to be_a_success
      .and not_to_output.to_stderr
  end

  it "prints installed formulae and casks with versions as JSON", :cask, :integration_test do
    install_formula_version "testball", "0.1"
    install_cask "local-caffeine"

    expect { brew_sh_list "--versions", "--json" }
      .to output(list_versions_json(
                   formulae: [{ name: "testball", versions: ["0.1"] }],
                   casks:    [{ token: "local-caffeine", versions: ["1.2.3"] }],
                 )).to_stdout
      .and not_to_output.to_stderr
      .and be_a_success
  end

  it "prints only installed formulae with versions as JSON", :cask, :integration_test do
    install_formula_version "testball", "0.1"
    install_cask "local-caffeine"

    expect { brew_sh_list "--versions", "--json", "--formula" }
      .to output(list_versions_json(
                   formulae: [{ name: "testball", versions: ["0.1"] }],
                 )).to_stdout
      .and not_to_output.to_stderr
      .and be_a_success
  end

  it "prints only installed casks with versions as JSON", :cask, :integration_test do
    install_formula_version "testball", "0.1"
    install_cask "local-caffeine"

    expect { brew_sh_list "--versions", "--json", "--cask" }
      .to output(list_versions_json(
                   casks: [{ token: "local-caffeine", versions: ["1.2.3"] }],
                 )).to_stdout
      .and not_to_output.to_stderr
      .and be_a_success
  end

  it "prints empty versions as JSON", :integration_test do
    expect { brew_sh_list "--versions", "--json" }
      .to output(list_versions_json).to_stdout
      .and not_to_output.to_stderr
      .and be_a_success
  end

  it "fails when JSON is requested without versions", :integration_test do
    expect { brew_sh_list "--json" }
      .to output("Error: `brew list --json` requires `--versions`.\n").to_stderr
      .and not_to_output.to_stdout
      .and be_a_failure
  end

  it "fails when JSON is requested with ls flags", :integration_test do
    expect { brew_sh_list "--versions", "--json", "-1" }
      .to output("Error: `brew list --versions --json` cannot be combined with `-1`, `-l`, `-r` or `-t`.\n")
      .to_stderr
      .and not_to_output.to_stdout
      .and be_a_failure
  end

  it "fails when JSON is requested for formulae and casks together", :integration_test do
    expect { brew_sh_list "--versions", "--json", "--formula", "--cask" }
      .to output("Error: `--formula` and `--cask` are mutually exclusive.\n").to_stderr
      .and not_to_output.to_stdout
      .and be_a_failure
  end

  it "prints linked, opt-linked and pinned versions as JSON", :cask, :integration_test do
    install_formula_version "testball", "0.1"
    install_formula_version "testball", "0.2"
    (HOMEBREW_PREFIX/"var/homebrew/linked").mkpath
    FileUtils.ln_s HOMEBREW_CELLAR/"testball/0.1", HOMEBREW_PREFIX/"var/homebrew/linked/testball"
    (HOMEBREW_PREFIX/"opt").mkpath
    FileUtils.ln_s HOMEBREW_CELLAR/"testball/0.2", HOMEBREW_PREFIX/"opt/testball"
    (HOMEBREW_PREFIX/"var/homebrew/pinned").mkpath
    FileUtils.ln_s HOMEBREW_CELLAR/"testball/0.2", HOMEBREW_PREFIX/"var/homebrew/pinned/testball"

    install_cask "local-caffeine"
    (HOMEBREW_PREFIX/"var/homebrew/pinned_casks").mkpath
    FileUtils.ln_s Cask::Caskroom.path/"local-caffeine/1.2.3",
                   HOMEBREW_PREFIX/"var/homebrew/pinned_casks/local-caffeine"

    expect { brew_sh_list "--versions", "--json" }
      .to output(list_versions_json(
                   formulae: [
                     { name: "testball", versions: ["0.1", "0.2"], linked_version: "0.1",
                       optlinked_version: "0.2", pinned_version: "0.2" },
                   ],
                   casks:    [
                     { token: "local-caffeine", versions: ["1.2.3"], pinned_version: "1.2.3" },
                   ],
                 )).to_stdout
      .and not_to_output.to_stderr
      .and be_a_success
  end

  it "fails when jq is unavailable for versions JSON", :integration_test do
    mktmpdir do |dir|
      stdout, stderr, status = Open3.capture3(
        {
          "HOMEBREW_CELLAR"   => (dir/"Cellar").to_s,
          "HOMEBREW_CASKROOM" => (dir/"Caskroom").to_s,
          "HOMEBREW_PATH"     => dir.to_s,
          "HOMEBREW_PREFIX"   => (dir/"prefix").to_s,
          "PATH"              => dir.to_s,
        },
        "/bin/bash", "-c", 'source "$1"; shift; homebrew-list "$@"',
        "bash", (HOMEBREW_LIBRARY_PATH/"list.sh").to_s, "list", "--versions", "--json"
      )

      expect(status).to be_a_failure
      expect(stdout).to eq("")
      expect(stderr).to eq("Error: jq is required for brew list --versions --json.\n")
    end
  end

  it "fails when versions JSON reaches the Ruby fallback", :integration_test do
    expect { brew "list", "--versions", "--json" }
      .to output(/`brew list --versions --json` is only supported by the fast Bash path with `jq`\./).to_stderr
      .and not_to_output.to_stdout
      .and be_a_failure
  end

  it "fails clearly when JSON without versions reaches the Ruby fallback", :integration_test do
    expect { brew "list", "--json" }
      .to output(/`brew list --json` requires `--versions`\./).to_stderr
      .and not_to_output.to_stdout
      .and be_a_failure
  end

  it "prints pinned formulae and casks", :cask, :integration_test do
    setup_test_formula "testball", tab_attributes: { installed_on_request: true }
    Formula["testball"].pin
    cask = Cask::CaskLoader.load("local-caffeine")
    InstallHelper.stub_cask_installation(cask)
    cask.pin

    expect { brew "list", "--pinned", "--versions" }
      .to output("local-caffeine 1.2.3\ntestball 0.1\n").to_stdout
      .and be_a_success

    cask.unpin
  end

  it "fails only for explicitly named missing pinned packages", :cask, :integration_test do
    setup_test_formula "testball", tab_attributes: { installed_on_request: true }
    Formula["testball"].pin
    cask = Cask::CaskLoader.load("local-caffeine")
    InstallHelper.stub_cask_installation(cask)
    cask.pin

    expect { brew "list", "--pinned", "--versions", "testball", "local-caffeine", "missing" }
      .to output("local-caffeine 1.2.3\ntestball 0.1\n").to_stdout
      .and be_a_failure

    cask.unpin
  end

  it "warns for explicitly named unpinned packages", :cask, :integration_test do
    cask = Cask::CaskLoader.load("local-caffeine")
    InstallHelper.stub_cask_installation(cask)

    expect { brew "list", "--pinned", "--cask", "local-caffeine" }
      .to not_to_output.to_stdout
      .and output(/local-caffeine not pinned/).to_stderr
      .and be_a_success
  end

  it "does not fail for unpinned Caskroom entries without named arguments", :cask, :integration_test do
    (Cask::Caskroom.path/"broken").mkpath

    expect { brew "list", "--pinned", "--cask" }
      .to not_to_output.to_stdout
      .and be_a_success
  end
end
