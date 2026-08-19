# typed: strict
# frozen_string_literal: true

require "cask/installer"
require "install"
require "dependency"
require "test/support/fixtures/testball"

RSpec.describe Homebrew::Install do
  specify "::perform_preinstall_checks runs non-fatal preinstall diagnostics" do
    allow(described_class).to receive(:check_prefix)
    allow(described_class).to receive(:check_cpu)
    allow(described_class).to receive(:attempt_directory_creation)

    expect(Homebrew::Diagnostic).to receive(:checks)
      .with(:supported_configuration_checks, fatal: false)
      .ordered
    expect(Homebrew::Diagnostic).to receive(:checks)
      .with(:preinstall_checks, fatal: false)
      .ordered
    expect(Homebrew::Diagnostic).to receive(:checks)
      .with(:fatal_preinstall_checks)
      .ordered

    described_class.perform_preinstall_checks
  end

  describe "::fetch_formulae" do
    it "skips formulae whose fetch steps raise and continues with the rest" do
      good_fi = FormulaInstaller.new(formula("good-bottle") do
        T.bind(self, T.class_of(Formula))
        url "foo-1.0"
      end)
      bad_fi = FormulaInstaller.new(formula("bad-bottle") do
        T.bind(self, T.class_of(Formula))
        url "foo-1.0"
      end)
      [good_fi, bad_fi].each do |fi|
        allow(fi).to receive(:prelude_fetch)
        allow(fi).to receive(:prelude)
      end
      allow(good_fi).to receive(:enqueue_fetch)
      allow(bad_fi).to receive(:enqueue_fetch).and_raise("unexpected failure")

      expect do
        expect(described_class.fetch_formulae([good_fi, bad_fi])).to eq([good_fi])
      end.to output(/Error: bad-bottle: unexpected failure/).to_stderr
    end
  end

  describe "::reject_failed_downloads" do
    it "skips the formula whose download failed and keeps the rest" do
      bottle_spec = BottleSpecification.new
      bottle_spec.sha256(arm64_big_sur: "deadbeef" * 8)
      failed_bottle = Bottle.new(nil, bottle_spec, Utils::Bottles::Tag.from_symbol(:arm64_big_sur),
                                 name: "bad-bottle", pkg_version: PkgVersion.new(Version.new("1.0"), 0))
      bad_fi = instance_double(FormulaInstaller, formula: formula("bad-bottle") do
        T.bind(self, T.class_of(Formula))
        url "foo-1.0"
      end)
      good_fi = instance_double(FormulaInstaller, formula: formula("good-bottle") do
        T.bind(self, T.class_of(Formula))
        url "foo-1.0"
      end)
      download_queue = instance_double(Homebrew::DownloadQueue, failed_downloads: [failed_bottle])

      expect(described_class.reject_failed_downloads([bad_fi, good_fi], download_queue:)).to eq([good_fi])
    end
  end

  describe "::install_formulae" do
    it "returns installed formulae without cleaning them inline when cleanup is deferred" do
      formula = formula("good-bottle") do
        T.bind(self, T.class_of(Formula))
        url "foo-1.0"
      end
      formula_installer = instance_double(FormulaInstaller, formula:)

      expect(described_class).to receive(:install_formula).with(formula_installer, upgrade: false)
      expect(Homebrew::Cleanup).not_to receive(:install_formula_clean!)

      expect(described_class.install_formulae([formula_installer], cleanup: false)).to eq([formula])
    end

    it "skips a formula whose install raises and continues with the rest" do
      bad_fi = instance_double(FormulaInstaller, formula: formula("bad-bottle") do
        T.bind(self, T.class_of(Formula))
        url "foo-1.0"
      end)
      good_fi = instance_double(FormulaInstaller, formula: formula("good-bottle") do
        T.bind(self, T.class_of(Formula))
        url "foo-1.0"
      end)
      allow(Homebrew::Cleanup).to receive(:install_formula_clean!)
      allow(described_class).to receive(:install_formula).with(bad_fi, upgrade: false)
                                                         .and_raise("gzip decompression failed")
      expect(described_class).to receive(:install_formula).with(good_fi, upgrade: false)

      expect { described_class.install_formulae([bad_fi, good_fi]) }
        .to output(/Error: bad-bottle: gzip decompression failed/).to_stderr
    end
  end

  describe "::enqueue_cask_installers" do
    it "fetches source API downloads before enqueueing cask downloads" do
      source_download = instance_double(Homebrew::API::SourceDownload)
      installer = instance_double(
        Cask::Installer,
        cask:                                instance_double(Cask::Cask),
        enqueue_dependency_downloads:        nil,
        enqueue_downloads:                   nil,
        prelude_fetch_download:              source_download,
        source_download_requires_pre_fetch?: true,
      )
      download_queue = instance_double(Homebrew::DownloadQueue, failed_downloads: [])

      expect(download_queue).to receive(:enqueue).with(source_download).ordered
      expect(download_queue).to receive(:fetch)
        .with(only: Homebrew::API::SourceDownload, heading: "Downloading Cask files")
        .ordered
      expect(installer).to receive(:enqueue_downloads).ordered
      expect(download_queue).to receive(:fetch)
        .with(only: Cask::Download, heading: "Downloading Cask files")
        .ordered

      described_class.enqueue_cask_installers([installer], download_queue:)
    end

    it "marks a cask whose source API download fails" do
      source_download = Homebrew::API::SourceDownload.new("https://brew.sh/cask.rb", nil)
      installer = instance_double(
        Cask::Installer,
        cask:                                instance_double(Cask::Cask),
        prelude_fetch_download:              source_download,
        source_download_requires_pre_fetch?: true,
      )
      download_queue = instance_double(Homebrew::DownloadQueue, failed_downloads: [source_download])

      allow(download_queue).to receive(:enqueue)
      allow(download_queue).to receive(:fetch)
      expect(installer).to receive(:download_failed!)
      expect(installer).not_to receive(:enqueue_downloads)

      expect(described_class.enqueue_cask_installers([installer], download_queue:)).to be(false)
    end

    it "enqueues dependencies after fetching primary cask downloads" do
      cask = instance_double(Cask::Cask, to_s: "dependent-cask")
      installer = instance_double(Cask::Installer, cask:, source_download_requires_pre_fetch?: false)
      download_queue = instance_double(Homebrew::DownloadQueue, failed_downloads: [])

      expect(installer).to receive(:enqueue_downloads).ordered
      expect(download_queue).to receive(:fetch)
        .with(only: Cask::Download, heading: "Downloading Cask files")
        .ordered
      expect(installer).to receive(:enqueue_dependency_downloads).ordered

      described_class.enqueue_cask_installers([installer], download_queue:)
    end

    it "skips casks whose enqueue raises and continues with the rest" do
      bad_cask = instance_double(Cask::Cask, to_s: "bad-cask")
      bad_installer = instance_double(Cask::Installer, cask:                                bad_cask,
                                                       source_download_requires_pre_fetch?: false)
      allow(bad_installer).to receive(:enqueue_downloads)
        .and_raise(URI::InvalidURIError, 'bad URI (is not URI?): "https://example.com/bad -cask.dmg"')
      good_installer = instance_double(Cask::Installer, source_download_requires_pre_fetch?: false,
                                                        enqueue_dependency_downloads:        nil)
      expect(good_installer).to receive(:enqueue_downloads)

      download_queue = Homebrew::DownloadQueue.new(pour: true)
      begin
        expect { described_class.enqueue_cask_installers([bad_installer, good_installer], download_queue:) }
          .to output(/Error: bad-cask: bad URI/).to_stderr
      ensure
        download_queue.shutdown
      end
    end
  end

  describe "::print_dry_run_dependencies" do
    it "splits fresh installs and upgrades under separate headers" do
      fresh = formula("fresh-dep") do
        T.bind(self, T.class_of(Formula))
        url "foo-1.0"
      end
      installed = formula("installed-dep") do
        T.bind(self, T.class_of(Formula))
        url "foo-1.0"
      end
      allow(fresh).to receive(:any_version_installed?).and_return(false)
      allow(installed).to receive(:any_version_installed?).and_return(true)
      deps = [
        instance_double(Dependency, to_formula: fresh),
        instance_double(Dependency, to_formula: installed),
      ]

      expect { described_class.print_dry_run_dependencies(Testball.new, deps, &:name) }
        .to output(/Would install 1 dependency.*fresh-dep.*Would upgrade 1 dependency.*installed-dep/m).to_stdout
    end
  end
end
