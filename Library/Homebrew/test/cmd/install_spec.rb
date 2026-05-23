# typed: false
# frozen_string_literal: true

require "cmd/install"
require "cmd/shared_examples/args_parse"

RSpec.describe Homebrew::Cmd::InstallCmd do
  let(:klass) { Homebrew::Cmd::InstallCmd }

  include FileUtils

  it_behaves_like "parseable arguments"

  it "prints a formula dry-run plan when asking" do
    added = formula("added") do
      url "https://brew.sh/added-1.0.tar.gz"
    end
    changed = formula("changed") do
      url "https://brew.sh/changed-2.0.tar.gz"
    end
    added_installer = FormulaInstaller.new(added)
    changed_installer = FormulaInstaller.new(changed)
    dependants = Homebrew::Upgrade::Dependents.new(upgradeable: [], pinned: [], skipped: [])

    allow(added_installer).to receive(:compute_dependencies).and_return([])
    allow(changed_installer).to receive(:compute_dependencies).and_return([])

    expect do
      Homebrew::Install.ask_formulae(
        [added_installer, changed_installer],
        dependants,
        prompt: false,
      )
    end.to output(<<~EOS).to_stdout
      ==> Would install 2 formulae:
      added changed
    EOS
  end

  it "skips ask input when asking for only requested formulae" do
    formula = formula("testball") do
      url "https://brew.sh/testball-0.1.tar.gz"
    end
    formula_installer = FormulaInstaller.new(formula)
    dependants = Homebrew::Upgrade::Dependents.new(upgradeable: [], pinned: [], skipped: [])

    allow(formula_installer).to receive(:compute_dependencies).and_return([])
    expect(Homebrew::Install).not_to receive(:ask_input)

    expect do
      Homebrew::Install.ask_formulae(
        [formula_installer],
        dependants,
      )
    end.to output(<<~EOS).to_stdout
      ==> Would install 1 formula:
      testball
    EOS
  end

  it "uses the requested action when asking for formulae with dependencies" do
    formula = formula("changed") do
      url "https://brew.sh/changed-2.0.tar.gz"
    end
    dependency = formula("dependency") do
      url "https://brew.sh/dependency-1.0.tar.gz"
    end
    formula_installer = FormulaInstaller.new(formula)
    dependants = Homebrew::Upgrade::Dependents.new(upgradeable: [], pinned: [], skipped: [])

    allow(formula_installer).to receive(:compute_dependencies)
      .and_return([instance_double(Dependency, to_formula: dependency)])
    expect(Homebrew::Install).to receive(:ask_input).with(action: "upgrade")

    expect do
      Homebrew::Install.ask_formulae(
        [formula_installer],
        dependants,
        action: "upgrade",
      )
    end.to output(<<~EOS).to_stdout
      ==> Would upgrade 1 formula:
      changed
      ==> Would install 1 dependency for changed:
      dependency
    EOS
  end

  it "defaults ask input to no" do
    allow($stdin).to receive_messages(gets: "\n", tty?: true)
    allow_any_instance_of(StringIO).to receive(:tty?).and_return(true)

    expect do
      Homebrew::Install.ask(action: "upgrade")
    end.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      .and output("==> Do you want to proceed with the upgrade? [y/N]\n").to_stdout
  end

  it "skips ask input without a TTY" do
    allow($stdin).to receive(:tty?).and_return(false)
    expect($stdin).not_to receive(:gets)

    expect { Homebrew::Install.ask(action: "upgrade") }.not_to output.to_stdout
  end

  it "uses shared prompt rules for ask plans" do
    expect([
      Homebrew::Install.ask_prompt_needed?(planned_names: ["fish"], requested_names: ["fish"]),
      Homebrew::Install.ask_prompt_needed?(planned_names: ["fish", "openssl"], requested_names: ["fish"]),
      Homebrew::Install.ask_prompt_needed?(planned_names: ["fish"], requested_names: [], named: false),
      Homebrew::Install.ask_prompt_needed?(planned_names: ["fish"], requested_names: ["fish"], force: true),
      Homebrew::Install.ask_prompt_needed?(planned_names: [], requested_names: [], named: false),
    ]).to eq([false, true, true, true, false])
  end

  it "prints casks when asking", :cask do
    cask = Cask::CaskLoader.load(cask_path("local-caffeine"))

    expect do
      Homebrew::Install.ask_casks([cask], prompt: false)
    end.to output(<<~EOS).to_stdout
      ==> Would install 1 cask:
      local-caffeine
    EOS
  end

  it "prompts when asking for casks with dependencies", :cask do
    cask = Cask::CaskLoader.load(cask_path("local-caffeine"))
    dependency = instance_double(Dependency, installed?: false, name: "unar")
    cask_dependent = instance_double(CaskDependent)

    allow(CaskDependent).to receive(:new)
      .with(cask)
      .and_return(cask_dependent)
    allow(cask_dependent).to receive(:runtime_dependencies).and_return([dependency])
    expect(Homebrew::Install).to receive(:ask_input).with(action: "installation")

    expect do
      Homebrew::Install.ask_casks([cask])
    end.to output(<<~EOS).to_stdout
      ==> Would install 1 cask:
      local-caffeine
      ==> Would install 1 dependency for local-caffeine:
      unar
    EOS
  end

  it "does not read installed formula metadata for cask dependency dry-run plans", :cask do
    cask = Cask::CaskLoader.load(cask_path("local-caffeine"))
    dependency = instance_double(Dependency, installed?: false, name: "ripgrep")
    cask_dependent = instance_double(CaskDependent)

    allow(CaskDependent).to receive(:new)
      .with(cask)
      .and_return(cask_dependent)
    expect(cask_dependent).to receive(:runtime_dependencies)
      .with(read_from_tab: false, undeclared: false)
      .and_return([dependency])

    expect do
      Homebrew::Install.ask_casks([cask], prompt: false)
    end.to output(<<~EOS).to_stdout
      ==> Would install 1 cask:
      local-caffeine
      ==> Would install 1 dependency for local-caffeine:
      ripgrep
    EOS
  end

  it "prompts when asking for casks with cask dependencies", :cask do
    cask = Cask::CaskLoader.load(cask_path("with-depends-on-cask"))

    expect(Homebrew::Install).to receive(:ask_input).with(action: "installation")

    expect do
      Homebrew::Install.ask_casks([cask])
    end.to output(<<~EOS).to_stdout
      ==> Would install 1 cask:
      with-depends-on-cask
      ==> Would install 1 dependency for with-depends-on-cask:
      local-transmission-zip
    EOS
  end

  it "prints a cask reinstallation dry-run plan when asking", :cask do
    cask = Cask::CaskLoader.load(cask_path("local-caffeine"))

    expect do
      Homebrew::Install.ask_casks([cask], action: "reinstallation", prompt: false)
    end.to output(<<~EOS).to_stdout
      ==> Would reinstall 1 cask:
      local-caffeine
    EOS
  end

  it "does not prompt when skipped cask dependencies will not be installed", :cask do
    cask = Cask::CaskLoader.load(cask_path("with-depends-on-cask"))

    expect(Homebrew::Install).not_to receive(:ask_input)

    expect do
      Homebrew::Install.ask_casks([cask], skip_cask_deps: true)
    end.to output(<<~EOS).to_stdout
      ==> Would install 1 cask:
      with-depends-on-cask
    EOS
  end

  it "prints an ask mode environment hint when installing formulae" do
    cmd = klass.new(["testball"])
    download_queue = instance_double(Homebrew::DownloadQueue, fetch: nil, shutdown: nil)
    formula = formula("testball") { url "https://brew.sh/testball-0.1.tar.gz" }
    formula_installer = FormulaInstaller.new(formula)
    dependants = Homebrew::Upgrade::Dependents.new(upgradeable: [], pinned: [], skipped: [])

    allow(Tap).to receive_messages(with_formula_name: nil, with_cask_token: nil)
    allow(cmd.args.named).to receive(:to_formulae_and_casks).with(warn: false).and_return([formula])
    allow(Homebrew::Install).to receive(:perform_preinstall_checks_once)
    allow(Homebrew::Install).to receive(:check_cc_argv)
    allow(Homebrew::Upgrade).to receive(:dependants).and_return(dependants)
    allow(Homebrew::DownloadQueue).to receive(:new).and_return(download_queue)
    allow(Homebrew::Install).to receive_messages(install_formula?: true, formula_installers: [formula_installer],
                                                 enqueue_formulae: [formula_installer])
    allow(Homebrew::Install).to receive(:install_formulae)
    allow(Homebrew::Upgrade).to receive(:upgrade_dependents)
    allow(Homebrew::Cleanup).to receive(:periodic_clean!)
    allow(Homebrew.messages).to receive(:display_messages)

    expect { cmd.run }.to output(/Enable ask mode by setting `HOMEBREW_ASK=1`/).to_stdout
  end

  it "installs an explicitly requested tap before resolving a formula" do
    cmd = klass.new(["user/repo/foo"])
    tap = Tap.fetch("user", "repo")

    allow(Tap).to receive(:with_formula_name).with("user/repo/foo").and_return([tap, "foo"])
    expect(tap).to receive(:ensure_installed!).ordered
    expect(cmd.args.named).to receive(:to_formulae_and_casks).with(warn: false).ordered
                                                             .and_raise(TapFormulaUnavailableError.new(tap, "foo"))

    expect { cmd.run }.to output(/If you trust this tap/).to_stderr

    expect(Homebrew).to have_failed
  end

  it "does not install `homebrew/cask` when a cask remains unavailable" do
    cmd = klass.new(["foo"])
    cask_tap = CoreCaskTap.instance

    require "search"

    allow(Tap).to receive_messages(with_formula_name: nil, with_cask_token: nil, untapped_official_taps: [])
    allow(cmd.args.named).to receive(:to_formulae_and_casks).with(warn: false)
                                                            .and_raise(FormulaOrCaskUnavailableError.new("foo"))
    allow(cask_tap).to receive(:installed?).and_return(false)
    allow(Homebrew::Search).to receive(:search_names).and_return([[], []])

    expect(cask_tap).not_to receive(:ensure_installed!)

    expect { cmd.run }.to raise_error(SystemExit)

    expect(Homebrew).to have_failed
  end

  context "when using a bottle" do
    let(:formula_name) { "testball_bottle" }
    let(:formula_prefix) { HOMEBREW_CELLAR/formula_name/"0.1" }
    let(:formula_prefix_regex) { /#{Regexp.escape(formula_prefix)}/o }
    let(:option_file) { formula_prefix/"foo/test" }
    let(:bottle_file) { formula_prefix/"bin/helloworld" }

    it "installs a Formula", :integration_test do
      setup_test_formula formula_name

      expect { brew "install", formula_name }
        .to output(formula_prefix_regex).to_stdout
        .and output(/✔︎.*/m).to_stderr
        .and be_a_success
      expect(option_file).not_to be_a_file
      expect(bottle_file).to be_a_file

      uninstall_test_formula formula_name

      expect { brew "install", "--ask", formula_name }
        .to output(/.*Would install 1 formula:\s*#{formula_name}.*/).to_stdout
        .and output(/✔︎.*/m).to_stderr
        .and be_a_success
      expect(option_file).not_to be_a_file
      expect(bottle_file).to be_a_file

      uninstall_test_formula formula_name

      expect { brew "install", formula_name, { "HOMEBREW_FORBIDDEN_FORMULAE" => formula_name } }
        .to not_to_output(formula_prefix_regex).to_stdout
        .and output(/#{formula_name} was forbidden/).to_stderr
        .and be_a_failure
      expect(formula_prefix).not_to exist
    end

    it "installs a keg-only Formula", :integration_test do
      setup_test_formula formula_name, <<~RUBY
        keg_only "test reason"
      RUBY

      expect { brew "install", formula_name }
        .to output(formula_prefix_regex).to_stdout
        .and output(/✔︎.*/m).to_stderr
        .and be_a_success
      expect(option_file).not_to be_a_file
      expect(bottle_file).to be_a_file
      expect(HOMEBREW_PREFIX/"bin/helloworld").not_to be_a_file
    end
  end

  context "when building from source" do
    let(:formula_name) { "testball1" }

    it "installs a Formula", :integration_test do
      formula_prefix = HOMEBREW_CELLAR/formula_name/"0.1"
      formula_prefix_regex = /#{Regexp.escape(formula_prefix)}/o
      option_file = formula_prefix/"foo/test"
      always_built_file = formula_prefix/"bin/test"

      setup_test_formula formula_name

      expect { brew "install", formula_name, "--with-foo" }
        .to output(formula_prefix_regex).to_stdout
        .and output(/✔︎.*/m).to_stderr
        .and be_a_success
      expect(option_file).to be_a_file
      expect(always_built_file).to be_a_file

      uninstall_test_formula formula_name

      expect { brew "install", formula_name, "--debug-symbols", "--build-from-source" }
        .to output(formula_prefix_regex).to_stdout
        .and output(/✔︎.*/m).to_stderr
        .and be_a_success
      expect(option_file).not_to be_a_file
      expect(always_built_file).to be_a_file
      expect(formula_prefix/"bin/test.dSYM/Contents/Resources/DWARF/test").to be_a_file if OS.mac?
      expect(HOMEBREW_CACHE/"Sources/#{formula_name}").to be_a_directory
    end

    it "installs a HEAD Formula", :integration_test do
      testball1_prefix = HOMEBREW_CELLAR/"testball1/HEAD-d5eb689"
      repo_path = HOMEBREW_CACHE/"repo"
      (repo_path/"bin").mkpath

      repo_path.cd do
        system "git", "-c", "init.defaultBranch=master", "init"
        system "git", "remote", "add", "origin", "https://github.com/Homebrew/homebrew-foo"
        FileUtils.touch "bin/something.bin"
        FileUtils.touch "README"
        system "git", "add", "--all"
        system "git", "commit", "-m", "Initial repo commit"
      end

      setup_test_formula "testball1", <<~RUBY
        version "1.0"

        head "file://#{repo_path}", using: :git

        def install
          prefix.install Dir["*"]
        end
      RUBY

      expect { brew "install", formula_name, "--HEAD", "HOMEBREW_DOWNLOAD_CONCURRENCY" => "1" }
        .to output(/#{Regexp.escape(testball1_prefix)}/o).to_stdout
        .and output(/Cloning into/).to_stderr
        .and be_a_success
      expect(testball1_prefix/"foo/test").not_to be_a_file
      expect(testball1_prefix/"bin/something.bin").to be_a_file
    end
  end

  it "prints a shared fetch heading and correct upgrade count", :cask do
    cmd = klass.new(["codex"])
    download_queue = instance_double(Homebrew::DownloadQueue, fetch: nil, shutdown: nil)
    formula = formula("testball_bottle") { url "https://brew.sh/testball_bottle-0.1.tar.gz" }
    formula_installer = instance_double(FormulaInstaller, formula:)
    cask = Cask::CaskLoader.load(cask_path("local-caffeine"))
    installer = instance_double(Cask::Installer, prelude: nil, enqueue_downloads: nil)

    allow(Tap).to receive_messages(with_formula_name: nil, with_cask_token: nil)
    allow(cmd.args.named).to receive(:to_formulae_and_casks).with(warn: false).and_return([formula, cask])
    allow(cask).to receive_messages(
      installed?:        true,
      full_name:         "codex",
      installed_version: "0.117.0",
      version:           "0.118.0",
    )
    allow(Cask::Upgrade).to receive(:outdated_casks).and_return([cask])
    allow(Homebrew::DownloadQueue).to receive(:new).and_return(download_queue)
    allow(Homebrew::Install).to receive(:install_formula?).and_return(true)
    allow(Homebrew::Install).to receive(:perform_preinstall_checks_once)
    allow(Homebrew::Install).to receive(:check_cc_argv)
    allow(Homebrew::Upgrade).to receive(:dependants).and_return(Homebrew::Upgrade::Dependents.new(
                                                                  upgradeable: [],
                                                                  pinned:      [],
                                                                  skipped:     [],
                                                                ))
    allow(Homebrew::Install).to receive_messages(
      formula_installers: [formula_installer],
      enqueue_formulae:   [formula_installer],
    )
    allow(Cask::Installer).to receive(:new).and_return(installer)
    allow(Homebrew::Install).to receive(:install_formulae)
    allow(Homebrew::Upgrade).to receive(:upgrade_dependents)
    allow(Homebrew::Cleanup).to receive(:periodic_clean!)
    allow(Homebrew.messages).to receive(:display_messages)
    allow(Cask::Upgrade).to receive(:upgrade_casks!) do |*_, **kwargs|
      expect(kwargs[:skip_prefetch]).to be(true)
      expect(kwargs[:show_upgrade_summary]).to be(false)

      true
    end

    expect { cmd.run }.to output(<<~EOS).to_stdout
      ==> Upgrading 1 outdated package:
      codex 0.117.0 -> 0.118.0
      ==> Fetching downloads for: testball_bottle and codex
    EOS
  end
end
