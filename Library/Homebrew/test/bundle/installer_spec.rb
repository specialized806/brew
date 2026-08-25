# typed: true
# frozen_string_literal: true

require "bundle"
require "attestation"
require "bundle/dsl"
require "bundle/installer"
require "trust"

RSpec.describe Homebrew::Bundle::Installer do
  let(:formula_entry) { Homebrew::Bundle::Dsl::Entry.new(:brew, "mysql") }
  let(:second_formula_entry) { Homebrew::Bundle::Dsl::Entry.new(:brew, "redis") }
  let(:cask_options) { { args: {}, full_name: "homebrew/cask/google-chrome" } }
  let(:cask_entry) { Homebrew::Bundle::Dsl::Entry.new(:cask, "google-chrome", cask_options) }
  let(:flatpak_entry) do
    Homebrew::Bundle::Dsl::Entry.new(:flatpak, "org.gnome.Calculator", { remote: "flathub" })
  end

  before do
    described_class.reset!
    allow(Homebrew::Bundle::Skipper).to receive(:skip?).and_return(false)
    allow(Homebrew::Bundle::Brew).to receive_messages(formula_upgradable?: false, install!: true)
    allow(Homebrew::Bundle::Brew).to receive_messages(formula_installed_and_up_to_date?: false,
                                                      preinstall!:                       true)
    allow(Homebrew::Bundle::Cask).to receive_messages(cask_upgradable?: false, install!: true)
    allow(Homebrew::Bundle::Cask).to receive_messages(installable_or_upgradable?: true, preinstall!: true)
    allow(Homebrew::Bundle::Tap).to receive_messages(preinstall!: true, install!: true, installed_taps: [])
    # Formula entries are installed in one batched `brew install`, so specs asserting a
    # specific `Bundle.brew` call need the others to fall through to a stub.
    allow(Homebrew::Bundle).to receive(:brew).and_return(true)
    # Entries can name a tap the Brewfile does not, which is otherwise cloned for real.
    allow_any_instance_of(::Tap).to receive(:ensure_installed!)
  end

  it "resets cached package state before installing" do
    expect(Homebrew::Bundle::Cask).to receive(:casks).twice.and_return(
      [double(to_s: "stale")],
      [double(to_s: "google-chrome")],
    )

    expect(Homebrew::Bundle::Cask.cask_names).to eq(["stale"])

    described_class.reset!
    described_class.install!([cask_entry], verbose: false, force: false, quiet: true)
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

  it "fails a missing Flatpak entry without skipping following entries or claiming success" do
    tap_entry = Homebrew::Bundle::Dsl::Entry.new(:tap, "example/tap")
    allow(Homebrew::Bundle::Flatpak).to receive(:package_manager_executable).and_return(nil)
    expect(Homebrew::Bundle::Tap).to receive(:preinstall!)
      .with("example/tap", no_upgrade: false, verbose: false)
      .and_return(true)
    expect(Homebrew::Bundle::Tap).to receive(:install!)
      .with("example/tap", preinstall: true, no_upgrade: false, verbose: false, force: false)
      .and_return(true)

    result = T.let(nil, T.nilable(T::Boolean))
    expect do
      result = described_class.install!([flatpak_entry, tap_entry], quiet: false)
    end.to output(
      /flatpak is not installed.*Installing org\.gnome\.Calculator has failed!.*`brew bundle` failed!/m,
    ).to_stderr.and not_to_output(/Using org\.gnome\.Calculator/).to_stdout
    expect(result).to be(false)
  end

  it "skips fetching formulae from untapped taps" do
    tap_entry = Homebrew::Bundle::Dsl::Entry.new(:tap, "homebrew/foo")
    tapped_formula_entry = Homebrew::Bundle::Dsl::Entry.new(:brew, "homebrew/foo/bar")

    allow(Homebrew::Bundle::Brew).to receive(:formula_installed_and_up_to_date?)
      .with("homebrew/foo/bar", no_upgrade: false).and_return(false)

    expect(Homebrew::Bundle).not_to receive(:brew).with("fetch", any_args)

    described_class.install!([tap_entry, tapped_formula_entry], quiet: true)
  end

  it "trusts `trusted: true` formulae before fetching them" do
    trusted_formula_entry = Homebrew::Bundle::Dsl::Entry.new(:brew, "thirdparty/tap/bar", { trusted: true })

    allow(Homebrew::Bundle::Tap).to receive(:installed_taps).and_return(["thirdparty/tap"])

    expect(Homebrew::Trust).to receive(:trust!).with(:formula, "thirdparty/tap/bar").ordered.and_return(true)
    expect(Homebrew::Bundle).to receive(:brew)
      .with("fetch", "thirdparty/tap/bar", verbose: false)
      .ordered
      .and_return(true)

    described_class.install!([trusted_formula_entry], quiet: true)
  end

  it "trusts `trusted: true` casks before fetching them" do
    options = { args: {}, full_name: "thirdparty/tap/baz", trusted: true }
    trusted_cask_entry = Homebrew::Bundle::Dsl::Entry.new(:cask, "baz", options)

    allow(Homebrew::Bundle::Tap).to receive(:installed_taps).and_return(["thirdparty/tap"])

    expect(Homebrew::Trust).to receive(:trust!).with(:cask, "thirdparty/tap/baz").ordered.and_return(true)
    expect(Homebrew::Bundle).to receive(:brew)
      .with("fetch", "thirdparty/tap/baz", verbose: false)
      .ordered
      .and_return(true)

    described_class.install!([trusted_cask_entry], quiet: true)
  end

  it "trusts `trusted: true` taps by name" do
    tap_entry = Homebrew::Bundle::Dsl::Entry.new(:tap, "thirdparty/tap", { trusted: true })

    expect(Homebrew::Trust).to receive(:trust!).with(:tap, "thirdparty/tap").and_return(true)

    described_class.install!([tap_entry], quiet: true)
  end

  it "trusts `trusted: true` taps with a clone target by their remote reference" do
    tap_entry = Homebrew::Bundle::Dsl::Entry.new(
      :tap, "thirdparty/custom", { clone_target: "https://github.com/thirdparty/homebrew-custom", trusted: true }
    )

    expect(Homebrew::Trust).to receive(:trust!).with(:tap, "thirdparty/custom").and_return(true)

    described_class.install!([tap_entry], quiet: true)
  end

  it "trusts tap `trusted` hash entries" do
    tap_entry = Homebrew::Bundle::Dsl::Entry.new(
      :tap, "thirdparty/tap",
      {
        trusted: {
          formula:  "foo",
          formulae: ["bar"],
          cask:     "baz",
          casks:    ["qux"],
          command:  "hello",
          commands: ["world"],
        },
      }
    )

    expect(Homebrew::Trust).to receive(:trust!).with(:formula, "thirdparty/tap/foo").and_return(true)
    expect(Homebrew::Trust).to receive(:trust!).with(:formula, "thirdparty/tap/bar").and_return(true)
    expect(Homebrew::Trust).to receive(:trust!).with(:cask, "thirdparty/tap/baz").and_return(true)
    expect(Homebrew::Trust).to receive(:trust!).with(:cask, "thirdparty/tap/qux").and_return(true)
    expect(Homebrew::Trust).to receive(:trust!).with(:command, "thirdparty/tap/hello").and_return(true)
    expect(Homebrew::Trust).to receive(:trust!).with(:command, "thirdparty/tap/world").and_return(true)

    described_class.install!([tap_entry], quiet: true)
  end

  it "rejects unsupported tap `trusted` hash keys" do
    tap_entry = Homebrew::Bundle::Dsl::Entry.new(:tap, "thirdparty/tap", { trusted: { tap: "foo" } })

    expect { described_class.install!([tap_entry], quiet: true) }
      .to raise_error(UsageError, /Unsupported trusted keys: tap/)
  end

  it "does not trust unqualified `trusted: true` names" do
    trusted_formula_entry = Homebrew::Bundle::Dsl::Entry.new(:brew, "mysql", { trusted: true })

    expect(Homebrew::Bundle::Trust.entries([trusted_formula_entry])).to be_empty
  end

  it "skips fetching formulae from fully qualified untapped taps" do
    tapped_formula_entry = Homebrew::Bundle::Dsl::Entry.new(:brew, "homebrew/foo/bar")

    allow(Homebrew::Bundle::Brew).to receive(:formula_installed_and_up_to_date?)
      .with("homebrew/foo/bar", no_upgrade: false).and_return(false)

    expect(Homebrew::Bundle).not_to receive(:brew).with("fetch", any_args)

    described_class.install!([tapped_formula_entry], quiet: true)
  end

  it "skips fetching unqualified formulae when Brewfile taps are untapped" do
    tap_entry = Homebrew::Bundle::Dsl::Entry.new(:tap, "homebrew/foo")
    untapped_formula_entry = Homebrew::Bundle::Dsl::Entry.new(:brew, "bar")

    allow(Homebrew::API).to receive_messages(formula_name?: false, formula_aliases: {}, formula_renames: {})

    expect(Homebrew::Bundle).not_to receive(:brew).with("fetch", any_args)

    described_class.install!([tap_entry, untapped_formula_entry], quiet: true)
  end

  it "warns and skips fetching unqualified formulae when API metadata is unavailable" do
    tap_entry = Homebrew::Bundle::Dsl::Entry.new(:tap, "homebrew/foo")
    untapped_formula_entry = Homebrew::Bundle::Dsl::Entry.new(:brew, "bar")

    allow(Homebrew::API).to receive(:formula_name?).and_raise("API unavailable")

    expect(described_class).to receive(:opoo).with(/could not check API metadata: API unavailable/)
    expect(Homebrew::Bundle).not_to receive(:brew).with("fetch", any_args)

    described_class.install!([tap_entry, untapped_formula_entry], quiet: true)
  end

  it "prefetches unqualified formulae available without untapped Brewfile taps" do
    tap_entry = Homebrew::Bundle::Dsl::Entry.new(:tap, "homebrew/foo")
    formula_entry = Homebrew::Bundle::Dsl::Entry.new(:brew, "mysql")

    allow(Homebrew::API).to receive_messages(formula_name?: true, formula_aliases: {}, formula_renames: {})
    allow(Homebrew::Bundle::Brew).to receive(:formula_installed_and_up_to_date?)
      .with("mysql", no_upgrade: false).and_return(false)

    expect(Homebrew::Bundle).to receive(:brew)
      .with("fetch", "mysql", verbose: false)
      .and_return(true)

    described_class.install!([tap_entry, formula_entry], quiet: true)
  end

  it "skips fetching fully qualified casks from untapped taps" do
    tapped_cask_entry = Homebrew::Bundle::Dsl::Entry.new(:cask, "bar", args: {}, full_name: "homebrew/foo/bar")

    expect(Homebrew::Bundle).not_to receive(:brew).with("fetch", any_args)

    described_class.install!([tapped_cask_entry], quiet: true)
  end

  it "skips fetching unqualified casks when Brewfile taps are untapped" do
    tap_entry = Homebrew::Bundle::Dsl::Entry.new(:tap, "xykong/tap")
    untapped_cask_entry = Homebrew::Bundle::Dsl::Entry.new(:cask, "flux-markdown",
                                                           args: {}, full_name: "flux-markdown")

    allow(Homebrew::API).to receive_messages(cask_token?: false, cask_renames: {})

    expect(Homebrew::Bundle).not_to receive(:brew).with("fetch", any_args)

    described_class.install!([tap_entry, untapped_cask_entry], quiet: true)
  end

  it "prefetches unqualified casks available without untapped Brewfile taps" do
    tap_entry = Homebrew::Bundle::Dsl::Entry.new(:tap, "xykong/tap")
    cask_entry = Homebrew::Bundle::Dsl::Entry.new(:cask, "google-chrome", args: {}, full_name: "google-chrome")

    allow(Homebrew::API).to receive_messages(cask_token?: true, cask_renames: {})
    allow(Homebrew::Bundle::Cask).to receive(:installable_or_upgradable?)
      .with("google-chrome", no_upgrade: false, args: {}, full_name: "google-chrome").and_return(true)

    expect(Homebrew::Bundle).to receive(:brew)
      .with("fetch", "google-chrome", verbose: false)
      .and_return(true)

    described_class.install!([tap_entry, cask_entry], quiet: true)
  end

  describe "batched formula installation" do
    before do
      allow(Homebrew::Bundle).to receive(:brew).and_return(true)
    end

    it "installs formulae needing installation in a single `brew install`" do
      expect(Homebrew::Bundle).to receive(:brew)
        .with("install", "--formula", "mysql", "redis", verbose: false)
        .and_return(true)

      described_class.install!([formula_entry, second_formula_entry], quiet: true)
    end

    it "upgrades formulae needing upgrading in a single `brew upgrade`" do
      allow(Homebrew::Bundle::Brew).to receive(:formula_installed?).with("mysql").and_return(false)
      allow(Homebrew::Bundle::Brew).to receive(:formula_installed?).with("redis").and_return(true)

      expect(Homebrew::Bundle).to receive(:brew)
        .with("install", "--formula", "mysql", verbose: false)
        .and_return(true)
      expect(Homebrew::Bundle).to receive(:brew)
        .with("upgrade", "--formula", "redis", verbose: false)
        .and_return(true)

      described_class.install!([formula_entry, second_formula_entry], quiet: true)
    end

    it "counts every entry of a successful batch as installed" do
      expect(described_class.install!([formula_entry, second_formula_entry], quiet: true)).to be(true)
    end

    it "attributes a failed batch to the entries that are not installed afterwards" do
      allow(Homebrew::Bundle).to receive(:brew).with("install", any_args).and_return(false)
      allow(Homebrew::Bundle::Brew).to receive(:formula_installed_and_up_to_date?)
        .with("mysql", no_upgrade: false).and_return(true)
      allow(Homebrew::Bundle::Brew).to receive(:formula_installed_and_up_to_date?)
        .with("redis", no_upgrade: false).and_return(false)

      expect do
        expect(described_class.install!([formula_entry, second_formula_entry], quiet: true)).to be(false)
      end.to output(/Installing redis has failed!/).to_stderr
    end

    it "refreshes the cached view of what is installed before finishing each entry" do
      expect(Homebrew::Bundle::Brew).to receive(:reset!).and_call_original.ordered
      expect(Homebrew::Bundle::Brew).to receive(:install!)
        .with("mysql", preinstall: false, no_upgrade: false, verbose: false, force: false)
        .ordered
        .and_return(true)

      described_class.install!([formula_entry], quiet: true)
    end

    it "keeps an entry carrying options out of the batch" do
      service_entry = Homebrew::Bundle::Dsl::Entry.new(:brew, "redis", { restart_service: :changed })

      expect(Homebrew::Bundle).to receive(:brew)
        .with("install", "--formula", "mysql", verbose: false)
        .and_return(true)
      expect(Homebrew::Bundle::Brew).to receive(:install!)
        .with("redis", restart_service: :changed, preinstall: true, no_upgrade: false, verbose: false, force: false)
        .and_return(true)

      described_class.install!([formula_entry, service_entry], quiet: true)
    end

    it "keeps an entry needing a Brewfile tap out of the batch" do
      tap_entry = Homebrew::Bundle::Dsl::Entry.new(:tap, "homebrew/foo")
      tapped_entry = Homebrew::Bundle::Dsl::Entry.new(:brew, "bar")
      allow(Homebrew::API).to receive_messages(formula_name?: false, formula_aliases: {}, formula_renames: {})

      expect(Homebrew::Bundle).not_to receive(:brew).with("install", any_args)
      expect(Homebrew::Bundle::Brew).to receive(:install!)
        .with("bar", preinstall: true, no_upgrade: false, verbose: false, force: false)
        .and_return(true)

      described_class.install!([tap_entry, tapped_entry], quiet: true)
    end

    it "keeps an unloadable formula out of the batch" do
      allow(Formula).to receive(:[]).with("mysql").and_raise(FormulaUnavailableError, "mysql")

      expect(Homebrew::Bundle).not_to receive(:brew).with("install", any_args)
      expect(Homebrew::Bundle::Brew).to receive(:install!)
        .with("mysql", preinstall: true, no_upgrade: false, verbose: false, force: false)
        .and_return(true)

      described_class.install!([formula_entry], quiet: true)
    end

    it "keeps an already up-to-date entry out of the batch but still finishes it" do
      allow(Homebrew::Bundle::Brew).to receive(:preinstall!).with("mysql", any_args).and_return(false)

      expect(Homebrew::Bundle).not_to receive(:brew).with("install", any_args)
      expect(Homebrew::Bundle::Brew).to receive(:install!)
        .with("mysql", preinstall: false, no_upgrade: false, verbose: false, force: false)
        .and_return(true)

      expect { described_class.install!([formula_entry], quiet: false) }.to output(/Using mysql/).to_stdout
    end

    it "does not batch casks" do
      expect(Homebrew::Bundle).not_to receive(:brew).with("install", any_args)
      expect(Homebrew::Bundle::Cask).to receive(:install!)
        .with("google-chrome", **cask_options, preinstall: true, no_upgrade: false, verbose: false, force: false)
        .and_return(true)

      described_class.install!([cask_entry], quiet: true)
    end

    it "installs Brewfile taps before batching the formulae" do
      tap_entry = Homebrew::Bundle::Dsl::Entry.new(:tap, "homebrew/foo")
      order = []
      allow(Homebrew::Bundle::Tap).to receive(:install!) do |name, **_options|
        order << name
        true
      end
      allow(Homebrew::Bundle).to receive(:brew) do |*args, **_options|
        order << args.first
        true
      end

      described_class.install!([formula_entry, tap_entry], quiet: true)

      expect(order).to eq(["fetch", "homebrew/foo", "install"])
    end

    it "resolves `gh` before installing anything when verifying attestations" do
      order = []
      allow(Homebrew::EnvConfig).to receive(:verify_attestations?).and_return(true)
      allow(Homebrew::Attestation).to receive(:gh_executable) do
        order << "gh"
        Pathname("/fake/gh")
      end
      allow(Homebrew::Bundle).to receive(:brew) do |*args, **_options|
        order << args.first
        true
      end

      described_class.install!([formula_entry], quiet: true)

      expect(order.first).to eq("fetch")
      expect(order).to include("gh")
      expect(order.index("gh")).to be < order.index("install")
    end
  end
end
