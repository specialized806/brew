# typed: strict
# frozen_string_literal: true

require "upgrade"
require "formula_installer"
require "dependency"
require "keg"
require "pkg_version"
require "test/support/fixtures/testball"

RSpec.describe Homebrew::Upgrade do
  describe "::format_upgrade_summary" do
    it "aligns a large mixed list of package names and versions" do
      upgrades = [
        "sqlite 3.53.1 -> 3.53.2 (2.4MB)",
        "docker 29.5.2 -> 29.6.0 (9.3MB)",
        "gh 2.93.0 -> 2.95.0 (13.4MB)",
        "python@3.14 3.14.5 -> 3.14.6 (19.2MB)",
        "pnpm 11.5.1 -> 11.8.0 (4MB)",
        "usage 3.4.0 -> 3.5.2 (2.9MB)",
        "certifi 2026.5.20 -> 2026.6.17 (5.7KB)",
        "libvmaf 3.1.0 -> 3.2.0 (1.2MB)",
        "kubernetes-cli 1.36.1 -> 1.36.2 (18.2MB)",
        "jq 1.8.1 -> 1.8.2 (441KB)",
        "mise 2026.6.0 -> 2026.6.11 (34.8MB)",
        "sdl2 2.32.70 (636.8KB)",
        "opencode-desktop 1.14.48 -> 1.17.9",
        "slack 4.48.102 -> 4.50.140",
        "spotify 1.2.84.476 -> 1.2.92.148",
        "visual-studio-code 1.111.0 -> 1.125.1",
      ]

      expect(described_class.format_upgrade_summary(upgrades)).to eq([
        "sqlite              3.53.1     -> 3.53.2 (2.4MB)",
        "docker              29.5.2     -> 29.6.0 (9.3MB)",
        "gh                  2.93.0     -> 2.95.0 (13.4MB)",
        "python@3.14         3.14.5     -> 3.14.6 (19.2MB)",
        "pnpm                11.5.1     -> 11.8.0 (4MB)",
        "usage               3.4.0      -> 3.5.2 (2.9MB)",
        "certifi             2026.5.20  -> 2026.6.17 (5.7KB)",
        "libvmaf             3.1.0      -> 3.2.0 (1.2MB)",
        "kubernetes-cli      1.36.1     -> 1.36.2 (18.2MB)",
        "jq                  1.8.1      -> 1.8.2 (441KB)",
        "mise                2026.6.0   -> 2026.6.11 (34.8MB)",
        "sdl2                2.32.70 (636.8KB)",
        "opencode-desktop    1.14.48    -> 1.17.9",
        "slack               4.48.102   -> 4.50.140",
        "spotify             1.2.84.476 -> 1.2.92.148",
        "visual-studio-code  1.111.0    -> 1.125.1",
      ])
    end
  end

  describe "::upgrade_formula" do
    it "shows the version transition for an unlinked dependency installed at an older version" do
      python = formula("python@3.14") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/python-3.14.6.tgz"
      end
      kegs = ["2.7.14_2", "3.6.1", "3.6.4_4", "3.7.1"].map do |v|
        instance_double(Keg, version: PkgVersion.parse(v))
      end
      allow(python).to receive_messages(any_version_installed?: true, optlinked?: false, installed_kegs: kegs)
      dependency = instance_double(Dependency, to_formula: python)
      formula_installer = instance_double(
        FormulaInstaller, formula: Testball.new, compute_dependencies: [dependency]
      )

      expect { described_class.upgrade_formula(formula_installer, dry_run: true) }
        .to output(/Would upgrade.*python@3.14 3.7.1 -> 3.14.6/m).to_stdout
    end

    it "reports a failed upgrade instead of aborting the rest of the batch" do
      formula_installer = instance_double(FormulaInstaller, formula: Testball.new)
      allow(Homebrew::Install).to receive(:install_formula).and_raise("gzip decompression failed")

      expect do
        expect(described_class.upgrade_formula(formula_installer)).to be(false)
      end.to output(/Error: testball: gzip decompression failed/).to_stderr
    end
  end

  describe "::formula_installers" do
    it "explains when installed dependencies satisfy the bottle metadata" do
      dependent = formula("dependent") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/dependent-2.0"
      end
      formula_installer = instance_double(
        FormulaInstaller,
        bottle_tab_runtime_dependencies: { "dependency" => { "version" => "2.0", "revision" => "0" } },
        determine_bottle_tab_attributes: nil,
        fetch_bottle_tab:                nil,
        formula:                         dependent,
      )
      dependency = instance_double(Dependency)
      download_queue = instance_double(Homebrew::DownloadQueue, fetch: nil, shutdown: nil)

      allow(Migrator).to receive(:migrate_if_needed)
      allow(described_class).to receive(:create_formula_installer).and_return(formula_installer)
      allow(Homebrew::DownloadQueue).to receive(:new).and_return(download_queue)
      allow(Dependency).to receive(:new).with("dependency").and_return(dependency)
      allow(dependency).to receive(:installed?)
        .with(minimum_version: Version.new("2.0"), minimum_revision: 0)
        .and_return(true)

      expect do
        described_class.formula_installers([dependent], flags: [], dependents: true)
      end.to output(
        "==> Not upgrading dependent: installed runtime dependencies satisfy bottle metadata\n",
      ).to_stdout
    end
  end

  describe "::upgrade_dependents" do
    it "returns installed dependents unless they are primary formulae" do
      installed_dependent = formula("installed-dependent") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/installed-dependent-2.0"
      end
      primary_formula = formula("primary") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/primary-2.0"
      end
      FormulaInstaller.installed.merge([installed_dependent, primary_formula])
      dependants = Homebrew::Upgrade::Dependents.new(
        upgradeable: [installed_dependent, primary_formula], pinned: [], skipped: [],
      )

      expect(described_class.upgrade_dependents(dependants, [primary_formula], flags: []))
        .to contain_exactly(installed_dependent)
    end
  end
end
