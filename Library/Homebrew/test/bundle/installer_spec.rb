# typed: false
# frozen_string_literal: true

require "bundle"
require "bundle/dsl"
require "bundle/installer"
require "bundle/parallel_installer"

RSpec.describe Homebrew::Bundle::Installer do
  let(:formula_entry) { Homebrew::Bundle::Dsl::Entry.new(:brew, "mysql") }
  let(:second_formula_entry) { Homebrew::Bundle::Dsl::Entry.new(:brew, "redis") }
  let(:cask_options) { { args: {}, full_name: "homebrew/cask/google-chrome" } }
  let(:cask_entry) { Homebrew::Bundle::Dsl::Entry.new(:cask, "google-chrome", cask_options) }

  before do
    allow(Homebrew::Bundle::Skipper).to receive(:skip?).and_return(false)
    allow(Homebrew::Bundle::Brew).to receive_messages(formula_upgradable?: false, install!: true)
    allow(Homebrew::Bundle::Brew).to receive_messages(formula_installed_and_up_to_date?: false,
                                                      preinstall!:                       true)
    allow(Homebrew::Bundle::Cask).to receive_messages(cask_upgradable?: false, install!: true)
    allow(Homebrew::Bundle::Cask).to receive_messages(installable_or_upgradable?: true, preinstall!: true)
    allow(Homebrew::Bundle::Tap).to receive_messages(preinstall!: true, install!: true, installed_taps: [])
  end

  it "prefetches installable formulae and casks before installing" do
    allow(Homebrew::Bundle::Tap).to receive(:installed_taps).and_return(["homebrew/cask"])
    allow(Homebrew::Bundle::Brew).to receive(:formula_installed_and_up_to_date?)
      .with("mysql", no_upgrade: false).and_return(false)
    allow(Homebrew::Bundle::Cask).to receive(:installable_or_upgradable?)
      .with("google-chrome", no_upgrade: false, **cask_options).and_return(true)

    expect(Homebrew::Bundle).to receive(:brew)
      .with("fetch", "mysql", "homebrew/cask/google-chrome", verbose: false)
      .ordered
      .and_return(true)
    expect(Homebrew::Bundle::Brew).to receive(:preinstall!)
      .with("mysql", no_upgrade: false, verbose: false)
      .ordered
      .and_return(true)
    expect(Homebrew::Bundle::Cask).to receive(:preinstall!)
      .with("google-chrome", **cask_options, no_upgrade: false, verbose: false)
      .ordered
      .and_return(true)

    described_class.install!([formula_entry, cask_entry], verbose: false, force: false, quiet: true)
  end

  it "skips fetching when no formulae or casks need installation or upgrade" do
    allow(Homebrew::Bundle::Brew).to receive(:formula_installed_and_up_to_date?)
      .with("mysql", no_upgrade: true).and_return(true)

    expect(Homebrew::Bundle).not_to receive(:brew).with("fetch", any_args)

    described_class.install!([formula_entry], no_upgrade: true, quiet: true)
  end

  it "skips fetching formulae from untapped taps" do
    tap_entry = Homebrew::Bundle::Dsl::Entry.new(:tap, "homebrew/foo")
    tapped_formula_entry = Homebrew::Bundle::Dsl::Entry.new(:brew, "homebrew/foo/bar")

    allow(Homebrew::Bundle::Brew).to receive(:formula_installed_and_up_to_date?)
      .with("homebrew/foo/bar", no_upgrade: false).and_return(false)

    expect(Homebrew::Bundle).not_to receive(:brew).with("fetch", any_args)

    described_class.install!([tap_entry, tapped_formula_entry], quiet: true)
  end

  describe "parallel installation" do
    let(:alpha_entry) do
      Homebrew::Bundle::Installer::InstallableEntry.new(
        name:    "alpha",
        options: {},
        verb:    "Installing",
        cls:     Homebrew::Bundle::Brew,
      )
    end
    let(:beta_entry) do
      Homebrew::Bundle::Installer::InstallableEntry.new(
        name:    "beta",
        options: {},
        verb:    "Installing",
        cls:     Homebrew::Bundle::Brew,
      )
    end

    it "installs independent formulae in parallel with jobs > 1" do
      allow(Homebrew::Bundle::Brew).to receive(:formulae_by_full_name).with("alpha").and_return({ dependencies: [] })
      allow(Homebrew::Bundle::Brew).to receive(:formulae_by_full_name).with("beta").and_return({ dependencies: [] })
      expect(Homebrew::Bundle::Brew).to receive(:install!)
        .with("alpha", preinstall: true, no_upgrade: false, verbose: false, force: false)
        .and_return(true)
      expect(Homebrew::Bundle::Brew).to receive(:install!)
        .with("beta", preinstall: true, no_upgrade: false, verbose: false, force: false)
        .and_return(true)

      success, failure = Homebrew::Bundle::ParallelInstaller.new(
        [alpha_entry, beta_entry],
        jobs: 2, no_upgrade: false, verbose: false, force: false, quiet: true,
      ).run!

      expect(success).to eq(2)
      expect(failure).to eq(0)
    end

    it "serializes dependent formulae" do
      install_order = []
      allow(Homebrew::Bundle::Brew).to receive(:install!) do |name, **_options|
        install_order << name
        true
      end

      allow(Homebrew::Bundle::Brew).to receive(:formulae_by_full_name).with("alpha")
                                                                      .and_return({ dependencies: ["beta"] })
      allow(Homebrew::Bundle::Brew).to receive(:formulae_by_full_name).with("beta").and_return({ dependencies: [] })

      success, failure = Homebrew::Bundle::ParallelInstaller.new(
        [alpha_entry, beta_entry],
        jobs: 2, no_upgrade: false, verbose: false, force: false, quiet: true,
      ).run!

      expect(success).to eq(2)
      expect(failure).to eq(0)
      expect(install_order).to eq(["beta", "alpha"])
    end

    it "falls back to sequential with jobs=1" do
      allow(Homebrew::Bundle::Brew).to receive(:formula_installed_and_up_to_date?).with("mysql",
                                                                                        no_upgrade: false)
                                                                                  .and_return(false)
      allow(Homebrew::Bundle::Brew).to receive(:formula_installed_and_up_to_date?).with("redis",
                                                                                        no_upgrade: false)
                                                                                  .and_return(false)

      expect(Homebrew::Bundle::ParallelInstaller).not_to receive(:new)
      expect(Homebrew::Bundle).to receive(:brew).with("fetch", "mysql", "redis",
                                                      verbose: false).ordered.and_return(true)
      expect(Homebrew::Bundle::Brew).to receive(:preinstall!)
        .with("mysql", no_upgrade: false, verbose: false).ordered.and_return(true)
      expect(Homebrew::Bundle::Brew).to receive(:preinstall!)
        .with("redis", no_upgrade: false, verbose: false).ordered.and_return(true)

      described_class.install!([formula_entry, second_formula_entry], jobs: 1, quiet: true)
    end
  end
end
