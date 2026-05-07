# typed: false
# frozen_string_literal: true

require "cmd/shared_examples/args_parse"
require "cmd/upgrade"
require "cmd/shared_examples/reinstall_pkgconf_if_needed"

RSpec.describe Homebrew::Cmd::UpgradeCmd do
  include FileUtils

  it_behaves_like "parseable arguments"

  it "upgrades a Formula", :integration_test do
    formula_name = "testball_bottle"
    formula_rack = HOMEBREW_CELLAR/formula_name

    setup_test_formula formula_name

    (formula_rack/"0.0.1/foo").mkpath

    expect { brew "upgrade" }.to be_a_success

    expect(formula_rack/"0.1").to be_a_directory
    expect(formula_rack/"0.0.1").not_to exist

    uninstall_test_formula formula_name

    # links newer version when upgrade was interrupted
    (formula_rack/"0.1/foo").mkpath

    expect { brew "upgrade" }.to be_a_success

    expect(formula_rack/"0.1").to be_a_directory
    expect(HOMEBREW_PREFIX/"opt/#{formula_name}").to be_a_symlink
    expect(HOMEBREW_PREFIX/"var/homebrew/linked/#{formula_name}").to be_a_symlink

    uninstall_test_formula formula_name

    # upgrades with asking for user prompts
    (formula_rack/"0.0.1/foo").mkpath

    expect { brew "upgrade", "--ask" }
      .to output(/.*Formula\s*\(1\):\s*#{formula_name}.*/).to_stdout
      .and output(/✔︎.*/m).to_stderr

    expect(formula_rack/"0.1").to be_a_directory
    expect(formula_rack/"0.0.1").not_to exist

    uninstall_test_formula formula_name

    # refuses to upgrade a forbidden formula
    (formula_rack/"0.0.1/foo").mkpath

    expect { brew "upgrade", formula_name, { "HOMEBREW_FORBIDDEN_FORMULAE" => formula_name } }
      .to not_to_output(%r{#{formula_rack}/0\.1}o).to_stdout
      .and output(/#{formula_name} was forbidden/).to_stderr
      .and be_a_failure
    expect(formula_rack/"0.1").not_to exist
  end

  it "reports unavailable names via ofail and continues upgrading" do
    error = FormulaOrCaskUnavailableError.new("nonexistent")
    formula = instance_double(Formula, full_name: "testball")

    cmd = described_class.new(["testball", "nonexistent"])
    allow(cmd.args.named).to receive(:present?).and_return(true)
    allow(cmd.args.named).to receive(:to_formulae_and_casks_and_unavailable)
      .with(method: :resolve)
      .and_return([formula, error])

    allow(cmd).to receive_messages(upgrade_outdated_formulae!: true, upgrade_outdated_casks!: false)

    expect { cmd.run }
      .to output(/nonexistent/).to_stderr

    expect(Homebrew).to have_failed
  end

  it "catches cask upgrade errors and sets Homebrew.failed" do
    allow(Cask::Upgrade).to receive(:upgrade_casks!).and_raise(Cask::CaskError.new("test cask error"))

    cmd = described_class.new(["--cask"])
    expect { cmd.send(:upgrade_outdated_casks!, []) }
      .to output(/test cask error/).to_stderr

    expect(Homebrew).to have_failed
  end

  it "prints a combined upgrade summary before fetching combined downloads" do
    cmd = described_class.new([])
    download_queue = instance_double(Homebrew::DownloadQueue, fetch: nil, fetch_failed: false, shutdown: nil)
    cask = instance_double(
      Cask::Cask,
      artifacts:         [],
      full_name:         "codex",
      installed_version: "0.117.0",
      version:           "0.118.0",
    )
    installer = instance_double(Cask::Installer, prelude: nil, enqueue_downloads: nil)

    allow(Homebrew::DownloadQueue).to receive(:new).and_return(download_queue)
    allow(cmd).to receive(:upgrade_outdated_formulae!) do |_, prefetch_only: false,
                                                              prefetch_names: nil,
                                                              prefetch_upgrades: nil,
                                                              show_upgrade_summary: true,
                                                              **|
      if prefetch_only
        expect(show_upgrade_summary).to be(false)
        prefetch_names&.replace(["deno"])
        prefetch_upgrades&.replace(["deno 2.7.10 -> 2.7.11"])
      end

      true
    end
    allow(Cask::Upgrade).to receive(:outdated_casks).and_return([cask])
    allow(Cask::Installer).to receive(:new).and_return(installer)
    allow(Cask::Upgrade).to receive(:upgrade_casks!) do |*_, **kwargs|
      expect(kwargs[:skip_prefetch]).to be(true)
      expect(kwargs[:show_upgrade_summary]).to be(false)

      true
    end
    allow(Homebrew::Cleanup).to receive(:periodic_clean!)
    allow(Homebrew::Reinstall).to receive(:reinstall_pkgconf_if_needed!)
    allow(Homebrew.messages).to receive(:display_messages)

    expect { cmd.run }.to output(<<~EOS).to_stdout
      ==> Upgrading 2 outdated packages:
      deno 2.7.10 -> 2.7.11
      codex 0.117.0 -> 0.118.0
      ==> Fetching downloads for: deno and codex
    EOS
  end

  it "prints a dependencies metadata heading before formula prefetches" do
    cmd = described_class.new([])
    formula = formula("deno") do
      url "https://brew.sh/deno-2.7.11.tar.gz"

      bottle do
        root_url HOMEBREW_BOTTLE_DEFAULT_DOMAIN
        sha256 cellar: :any_skip_relocation,
               Utils::Bottles.tag.to_sym => "d7b9f4e8bf83608b71fe958a99f19f2e5e68bb2582965d32e41759c24f1aef97"
      end
    end
    formula_installer = FormulaInstaller.new(formula)
    download_queue = instance_double(Homebrew::DownloadQueue)

    allow(cmd).to receive(:formulae_upgrade_context).and_return(
      described_class::FormulaeUpgradeContext.new(
        formulae_to_install: [formula],
        formulae_installer:  [formula_installer],
        dependants:          Homebrew::Upgrade::Dependents.new(upgradeable: [], pinned: [], skipped: []),
      ),
    )
    allow(Homebrew::Install).to receive(:enqueue_formulae)
      .with([formula_installer], download_queue:)
      .and_return([formula_installer])

    expect do
      cmd.send(:upgrade_outdated_formulae!, [], prefetch_only: true, download_queue:, show_downloads_heading: false)
    end.to output("==> Fetching dependencies metadata\n").to_stdout
  end

  it "does not trust failed shared prefetches" do
    cmd = described_class.new([])
    download_queue = instance_double(Homebrew::DownloadQueue, fetch: nil, fetch_failed: true, shutdown: nil)
    cask = instance_double(
      Cask::Cask,
      artifacts:         [],
      full_name:         "codex",
      installed_version: "0.117.0",
      version:           "0.118.0",
    )
    installer = instance_double(Cask::Installer, prelude: nil, enqueue_downloads: nil)

    allow(Homebrew::DownloadQueue).to receive(:new).and_return(download_queue)
    allow(cmd).to receive(:upgrade_outdated_formulae!) do |_, prefetch_only: false,
                                                              use_prefetched: false,
                                                              prefetch_names: nil,
                                                              prefetch_upgrades: nil,
                                                              show_upgrade_summary: true,
                                                              **|
      if prefetch_only
        expect(show_upgrade_summary).to be(false)
        prefetch_names&.replace(["deno"])
        prefetch_upgrades&.replace(["deno 2.7.10 -> 2.7.11"])
      else
        expect(use_prefetched).to be(false)
        expect(show_upgrade_summary).to be(false)
      end

      true
    end
    allow(Cask::Upgrade).to receive(:outdated_casks).and_return([cask])
    allow(Cask::Installer).to receive(:new).and_return(installer)
    allow(Cask::Upgrade).to receive(:upgrade_casks!) do |*_, **kwargs|
      expect(kwargs[:skip_prefetch]).to be(false)
      expect(kwargs[:show_upgrade_summary]).to be(false)

      true
    end
    allow(Homebrew::Cleanup).to receive(:periodic_clean!)
    allow(Homebrew::Reinstall).to receive(:reinstall_pkgconf_if_needed!)
    allow(Homebrew.messages).to receive(:display_messages)

    cmd.run
  end

  it "does not print removed caveats method errors for installed casks", :cask do
    cask = Cask::CaskLoader.load(cask_path("local-caffeine"))
    installer = InstallHelper.install_with_caskfile(cask)
    installed_caskfile = installer.metadata_subdir/"#{cask.token}.rb"
    expect(installed_caskfile).to exist

    installed_caskfile.write(
      installed_caskfile.read.sub(
        /\nend\n\z/,
        <<~RUBY,
            caveats do
              discontinued
            end
          end
        RUBY
      ),
    )

    (CoreCaskTap.instance.cask_dir/"local-caffeine.rb").unlink
    CoreCaskTap.instance.clear_cache

    cmd = described_class.new(["--cask", "--dry-run"])

    expect { cmd.send(:upgrade_outdated_casks!, []) }
      .to not_to_output(/Unexpected method 'discontinued' called during caveats on Cask local-caffeine\./).to_stderr
  end

  it "prints a narrow final upgrade summary" do
    cmd = described_class.new([])
    summary = described_class::FinalUpgradeSummary.new(
      version_changes:       ["testball 0.1 -> 0.2"],
      pinned_formulae:       ["pinnedball 1.0"],
      deprecated:            ["oldball"],
      disabled:              ["disabledball"],
      source_build_formulae: ["sourceball"],
    )

    allow(cmd).to receive(:final_upgrade_summary).and_return(summary)

    expect { cmd.send(:show_final_upgrade_summary) }.to output(<<~EOS).to_stdout
      ==> Upgraded 1 outdated package
      testball 0.1 -> 0.2
      ==> 1 Pinned formula
      pinnedball 1.0
      ==> 2 Deprecated or disabled packages
      oldball (deprecated)
      disabledball (disabled)
      ==> 1 homebrew/core formula built from source
      sourceball
    EOS
  end

  it "records final formula upgrade summary details" do
    formula = formula("testball") do
      url "https://brew.sh/testball-0.2"
    end
    pinned = formula("pinnedball") do
      url "https://brew.sh/pinnedball-1.0"
    end
    deprecated = formula("oldball") do
      url "https://brew.sh/oldball-1.0"
      deprecate! date: "2020-01-01", because: :unmaintained
    end
    disabled = formula("disabledball") do
      url "https://brew.sh/disabledball-1.0"
      disable! date: "2020-01-01", because: :unsupported
    end
    source_build = formula("sourceball") do
      url "https://brew.sh/sourceball-1.0"
    end
    old_keg = HOMEBREW_CELLAR/"testball/0.1"
    old_keg.mkpath
    allow(formula).to receive_messages(optlinked?: true, opt_prefix: old_keg)

    cmd = described_class.new([])
    context = described_class::FormulaeUpgradeContext.new(
      formulae_to_install: [formula, deprecated, disabled, source_build],
      formulae_installer:  [
        FormulaInstaller.new(formula),
        FormulaInstaller.new(deprecated),
        FormulaInstaller.new(disabled),
        FormulaInstaller.new(source_build, build_from_source_formulae: [source_build.full_name]),
      ],
      dependants:          Homebrew::Upgrade::Dependents.new(upgradeable: [], pinned: [], skipped: []),
      pinned_formulae:     [pinned],
    )

    cmd.send(:record_formula_upgrade_summary, context)
    summary = cmd.send(:final_upgrade_summary)

    expect(summary.version_changes).to include("testball 0.1 -> 0.2")
    expect(summary.pinned_formulae).to include("pinnedball 1.0")
    expect(summary.deprecated).to include("oldball")
    expect(summary.disabled).to include("disabledball")
    expect(summary.source_build_formulae).to include("sourceball")
  end

  it "records formula upgrade versions before upgrading" do
    formula = formula("testball") do
      url "https://brew.sh/testball-0.2"
    end
    old_keg = HOMEBREW_CELLAR/"testball/0.1"
    new_keg = HOMEBREW_CELLAR/"testball/0.2"
    old_keg.mkpath
    new_keg.mkpath
    allow(formula).to receive_messages(optlinked?: true, opt_prefix: old_keg)
    cmd = described_class.new([])

    allow(cmd).to receive(:formulae_upgrade_context).and_return(
      described_class::FormulaeUpgradeContext.new(
        formulae_to_install: [formula],
        formulae_installer:  [FormulaInstaller.new(formula)],
        dependants:          Homebrew::Upgrade::Dependents.new(upgradeable: [], pinned: [], skipped: []),
      ),
    )
    allow(Homebrew::Upgrade).to receive(:upgrade_formulae) do
      allow(formula).to receive(:opt_prefix).and_return(new_keg)
    end
    allow(Homebrew::Upgrade).to receive(:upgrade_dependents)

    cmd.send(:upgrade_outdated_formulae!, [])

    expect(cmd.send(:final_upgrade_summary).version_changes).to include("testball 0.1 -> 0.2")
  end

  it_behaves_like "reinstall_pkgconf_if_needed"
end
