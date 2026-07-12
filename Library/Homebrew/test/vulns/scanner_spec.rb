# typed: false
# frozen_string_literal: true

require "vulns/scanner"

RSpec.describe Homebrew::Vulns::Scanner do
  describe ".repo_url" do
    it "extracts a GitHub repo from an archive/refs/tags URL" do
      url = "https://github.com/nektos/act/archive/refs/tags/v0.2.84.tar.gz"
      expect(described_class.repo_url(url)).to eq "https://github.com/nektos/act"
    end

    it "extracts a GitHub repo from a releases/download URL" do
      url = "https://github.com/owner/repo/releases/download/v1.2.3/source.tar.gz"
      expect(described_class.repo_url(url)).to eq "https://github.com/owner/repo"
    end

    it "extracts a GitHub repo from a .git URL" do
      expect(described_class.repo_url("https://github.com/AomediaOrg/aom.git"))
        .to eq "https://github.com/AomediaOrg/aom"
    end

    it "extracts a GitLab repo, stripping the /-/ path segment" do
      url = "https://gitlab.com/owner/repo/-/archive/v1.2.3/repo-v1.2.3.tar.gz"
      expect(described_class.repo_url(url)).to eq "https://gitlab.com/owner/repo"
    end

    it "extracts a Codeberg repo" do
      url = "https://codeberg.org/owner/repo/archive/v1.2.3.tar.gz"
      expect(described_class.repo_url(url)).to eq "https://codeberg.org/owner/repo"
    end

    it "falls back to the head URL when the stable URL is not a supported forge" do
      stable = "https://aomedia.googlesource.com/aom.git"
      head = "https://github.com/AomediaOrg/aom.git"
      expect(described_class.repo_url(stable, head)).to eq "https://github.com/AomediaOrg/aom"
    end

    it "returns nil for unsupported hosts" do
      expect(described_class.repo_url("https://example.com/source.tar.gz")).to be_nil
    end

    it "returns nil for nil input" do
      expect(described_class.repo_url(nil)).to be_nil
      expect(described_class.repo_url(nil, nil)).to be_nil
    end
  end

  describe ".tag" do
    it "extracts from archive/refs/tags .tar.gz" do
      expect(described_class.tag("https://github.com/nektos/act/archive/refs/tags/v0.2.84.tar.gz"))
        .to eq "v0.2.84"
    end

    it "extracts a tag without a v prefix" do
      url = "https://github.com/abseil/abseil-cpp/archive/refs/tags/20250814.1.tar.gz"
      expect(described_class.tag(url)).to eq "20250814.1"
    end

    it "extracts from archive/refs/tags .zip" do
      expect(described_class.tag("https://github.com/owner/repo/archive/refs/tags/v1.0.0.zip"))
        .to eq "v1.0.0"
    end

    it "extracts from archive/<tag>.tar.gz" do
      expect(described_class.tag("https://codeberg.org/owner/repo/archive/v1.2.3.tar.gz"))
        .to eq "v1.2.3"
    end

    it "extracts from releases/download/<tag>/" do
      url = "https://github.com/owner/repo/releases/download/v1.2.3/source.tar.gz"
      expect(described_class.tag(url)).to eq "v1.2.3"
    end

    it "extracts from tarball/<tag>" do
      expect(described_class.tag("https://github.com/owner/repo/tarball/v1.2.3")).to eq "v1.2.3"
    end

    it "returns nil when no tag pattern matches" do
      expect(described_class.tag("https://example.com/source.tar.gz")).to be_nil
      expect(described_class.tag(nil)).to be_nil
    end
  end

  describe ".resolved_ids" do
    it "collects security-type resolves across all patches, uppercased and deduplicated" do
      patches = [
        { "url"      => "https://deb.debian.org/foo.debian.tar.xz",
          "resolves" => [{ "type" => "security", "id" => "CVE-2016-2399" },
                         { "type" => "security", "id" => "CVE-2017-9122" }] },
        { "url"      => "https://example.com/extra.diff",
          "resolves" => [{ "type" => "security", "id" => "GHSA-xr7r-f8xq-vfvv" },
                         { "type" => "security", "id" => "CVE-2017-9122" }] },
      ]
      expect(described_class.resolved_ids(patches))
        .to eq ["CVE-2016-2399", "CVE-2017-9122", "GHSA-XR7R-F8XQ-VFVV"]
    end

    it "ignores defect-type resolves" do
      patches = [
        { "resolves" => [{ "type" => "defect", "id" => "https://bugs.example.com/1234" },
                         { "type" => "security", "id" => "CVE-2024-0001" }] },
      ]
      expect(described_class.resolved_ids(patches)).to eq ["CVE-2024-0001"]
    end

    it "returns empty for no patches" do
      expect(described_class.resolved_ids([])).to eq []
    end

    it "handles patches without a resolves key" do
      expect(described_class.resolved_ids([{ "url" => "https://example.com/x.diff" }])).to eq []
    end
  end

  describe ".source_url_from_sbom" do
    it "returns the -src package downloadLocation" do
      prefix = TEST_FIXTURE_DIR/"vulns"
      expect(described_class.source_url_from_sbom(prefix))
        .to eq "https://github.com/nektos/act/archive/refs/tags/v0.2.80.tar.gz"
    end

    it "returns nil when no SBOM file exists" do
      expect(described_class.source_url_from_sbom(Pathname("/nonexistent"))).to be_nil
    end

    it "returns nil for a NOASSERTION location" do
      Dir.mktmpdir do |dir|
        prefix = Pathname(dir)
        (prefix/"sbom.spdx.json").write JSON.generate(
          packages: [{ SPDXID: "SPDXRef-Archive-x-src", downloadLocation: "NOASSERTION" }],
        )
        expect(described_class.source_url_from_sbom(prefix)).to be_nil
      end
    end

    it "returns nil when the SBOM is unparseable" do
      Dir.mktmpdir do |dir|
        prefix = Pathname(dir)
        (prefix/"sbom.spdx.json").write "not json"
        expect(described_class.source_url_from_sbom(prefix)).to be_nil
      end
    end
  end

  describe "#scan" do
    let(:act) do
      formula("act") do
        url "https://github.com/nektos/act/archive/refs/tags/v0.2.84.tar.gz"
      end
    end

    let(:openssl) do
      formula("openssl@3") do
        url "https://github.com/openssl/openssl/releases/download/openssl-3.0.0/openssl-3.0.0.tar.gz"
      end
    end

    let(:unsupported) do
      formula("aom") do
        url "https://aomedia.googlesource.com/aom.git", tag: "v3.13.1"
      end
    end

    let(:libquicktime) do
      formula("libquicktime") do
        url "https://github.com/owner/libquicktime/archive/refs/tags/v1.2.4.tar.gz"
        patch do
          url "https://deb.debian.org/debian/pool/main/libq/libquicktime/libquicktime_1.2.4-12.debian.tar.xz"
          sha256 "abc"
          resolves "CVE-2016-2399", "CVE-2017-9122"
        end
      end
    end

    def osv_record(id, severity: "HIGH", **extra)
      { "id" => id, "database_specific" => { "severity" => severity } }.merge(extra)
    end

    before do
      allow(Homebrew::Vulns::OSV).to receive(:vulnerability) { |id| osv_record(id) }
    end

    it "returns findings for formulae with open vulnerabilities" do
      allow(Homebrew::Vulns::OSV).to receive(:query_batch).and_return(
        [[{ "id" => "CVE-2024-1111" }], []],
      )

      results = described_class.new([act, openssl]).scan

      expect(results.checked).to eq 2
      expect(results.skipped).to eq 0
      expect(results.any_open?).to be true
      expect(results.findings.size).to eq 1
      f = results.findings.first
      expect(f.name).to eq "act"
      expect(f.version).to eq "0.2.84"
      expect(f.tag).to eq "v0.2.84"
      expect(f.repo_url).to eq "https://github.com/nektos/act"
      expect(f.open.map(&:id)).to eq ["CVE-2024-1111"]
      expect(f.patched).to eq []
    end

    it "reports empty results when nothing is found" do
      allow(Homebrew::Vulns::OSV).to receive(:query_batch).and_return([[], []])
      results = described_class.new([act, openssl]).scan
      expect(results.any_open?).to be false
      expect(results.findings).to eq []
    end

    it "skips formulae without a queryable repo URL and tag" do
      allow(Homebrew::Vulns::OSV).to receive(:query_batch).with(
        [{ repo_url: "https://github.com/nektos/act", version: "v0.2.84" }],
      ).and_return([[]])

      results = described_class.new([act, unsupported]).scan

      expect(results.checked).to eq 1
      expect(results.skipped).to eq 1
    end

    it "queries nothing when no formula is queryable" do
      expect(Homebrew::Vulns::OSV).not_to receive(:query_batch)
      results = described_class.new([unsupported]).scan
      expect(results.checked).to eq 0
      expect(results.skipped).to eq 1
      expect(results.findings).to eq []
    end

    it "fetches full records for each returned vuln id" do
      allow(Homebrew::Vulns::OSV).to receive(:query_batch)
        .and_return([[{ "id" => "CVE-2024-1111" }, { "id" => "CVE-2024-2222" }]])
      expect(Homebrew::Vulns::OSV).to receive(:vulnerability).with("CVE-2024-1111").and_return(
        osv_record("CVE-2024-1111", severity: "CRITICAL"),
      )
      expect(Homebrew::Vulns::OSV).to receive(:vulnerability).with("CVE-2024-2222").and_return(
        osv_record("CVE-2024-2222", severity: "LOW"),
      )

      results = described_class.new([act]).scan

      expect(results.findings.first.open.map(&:id)).to contain_exactly("CVE-2024-1111", "CVE-2024-2222")
    end

    it "drops vulnerabilities that do not affect the queried tag" do
      allow(Homebrew::Vulns::OSV).to receive(:query_batch).and_return([[{ "id" => "CVE-2024-1111" }]])
      allow(Homebrew::Vulns::OSV).to receive(:vulnerability).with("CVE-2024-1111").and_return(
        osv_record("CVE-2024-1111",
                   "affected" => [{ "ranges" => [{ "type"   => "SEMVER",
                                                   "events" => [{ "introduced" => "0" },
                                                                { "fixed" => "0.2.0" }] }] }]),
      )

      results = described_class.new([act]).scan

      expect(results.findings).to eq []
    end

    it "filters below the minimum severity" do
      allow(Homebrew::Vulns::OSV).to receive(:query_batch)
        .and_return([[{ "id" => "CVE-LOW" }, { "id" => "CVE-CRIT" }]])
      allow(Homebrew::Vulns::OSV).to receive(:vulnerability).with("CVE-LOW")
                                                            .and_return(osv_record("CVE-LOW", severity: "LOW"))
      allow(Homebrew::Vulns::OSV).to receive(:vulnerability).with("CVE-CRIT")
                                                            .and_return(osv_record("CVE-CRIT", severity: "CRITICAL"))

      results = described_class.new([act], min_severity: :high).scan

      expect(results.findings.first.open.map(&:id)).to eq ["CVE-CRIT"]
    end

    it "moves vulnerabilities resolved by formula patches into patched" do
      allow(Homebrew::Vulns::OSV).to receive(:query_batch)
        .and_return([[{ "id" => "CVE-2016-2399" }, { "id" => "CVE-2024-9999" }]])
      allow(Homebrew::Vulns::OSV).to receive(:vulnerability).with("CVE-2016-2399")
                                                            .and_return(osv_record("CVE-2016-2399"))
      allow(Homebrew::Vulns::OSV).to receive(:vulnerability).with("CVE-2024-9999")
                                                            .and_return(osv_record("CVE-2024-9999"))

      results = described_class.new([libquicktime]).scan

      finding = results.findings.first
      expect(finding.open.map(&:id)).to eq ["CVE-2024-9999"]
      expect(finding.patched.map(&:id)).to eq ["CVE-2016-2399"]
      expect(results.any_open?).to be true
    end

    it "matches patch resolves against vulnerability aliases case-insensitively" do
      allow(Homebrew::Vulns::OSV).to receive(:query_batch).and_return([[{ "id" => "GHSA-x" }]])
      allow(Homebrew::Vulns::OSV).to receive(:vulnerability).with("GHSA-x")
                                                            .and_return(osv_record("GHSA-x",
                                                                                   "aliases" => ["cve-2017-9122"]))

      results = described_class.new([libquicktime]).scan

      expect(results.findings.first.open).to eq []
      expect(results.findings.first.patched.map(&:id)).to eq ["GHSA-x"]
      expect(results.any_open?).to be false
    end

    it "does not conflate formulae with the same short name from different taps" do
      core_thing = formula("thing", tap: CoreTap.instance) do
        url "https://github.com/owner-a/thing/archive/refs/tags/v1.0.0.tar.gz"
      end
      tap_thing = formula("thing", tap: Tap.fetch("someone", "tap")) do
        url "https://github.com/owner-b/thing/archive/refs/tags/v2.0.0.tar.gz"
      end
      expect(core_thing.name).to eq tap_thing.name

      queried = nil
      allow(Homebrew::Vulns::OSV).to receive(:query_batch) do |packages|
        queried = packages
        Array.new(packages.size) { [] }
      end

      described_class.new([core_thing, tap_thing]).scan

      expect(queried).to eq [
        { repo_url: "https://github.com/owner-a/thing", version: "v1.0.0" },
        { repo_url: "https://github.com/owner-b/thing", version: "v2.0.0" },
      ]
    end

    it "keeps resolved vulnerabilities in open when ignore_patches is false" do
      allow(Homebrew::Vulns::OSV).to receive(:query_batch).and_return([[{ "id" => "CVE-2016-2399" }]])

      results = described_class.new([libquicktime], ignore_patches: false).scan

      expect(results.findings.first.open.map(&:id)).to eq ["CVE-2016-2399"]
      expect(results.findings.first.patched).to eq []
    end

    it "does not suppress via patches when the scanned keg predates the current recipe" do
      allow(libquicktime).to receive_messages(
        any_installed_prefix:  Pathname("/nonexistent"),
        any_installed_version: PkgVersion.parse("1.2.3"),
        installed_kegs:        [instance_double(Keg, version: PkgVersion.parse("1.2.3"))],
      )
      allow(Homebrew::Vulns::OSV).to receive(:query_batch).and_return([[{ "id" => "CVE-2016-2399" }]])

      results = described_class.new([libquicktime]).scan

      expect(results.findings.first.open.map(&:id)).to eq ["CVE-2016-2399"]
      expect(results.findings.first.patched).to eq []
    end

    it "does not suppress when the opt-linked keg is old even if the current version is also installed" do
      allow(libquicktime).to receive_messages(
        any_installed_prefix:      Pathname("/nonexistent"),
        any_installed_version:     PkgVersion.parse("1.2.3"),
        installed_kegs:            [instance_double(Keg, version: PkgVersion.parse("1.2.3")),
                                    instance_double(Keg, version: libquicktime.pkg_version)],
        latest_version_installed?: true,
      )
      allow(Homebrew::Vulns::OSV).to receive(:query_batch).and_return([[{ "id" => "CVE-2016-2399" }]])

      results = described_class.new([libquicktime]).scan

      expect(results.findings.first.open.map(&:id)).to eq ["CVE-2016-2399"]
      expect(results.findings.first.patched).to eq []
      expect(results.outdated_without_sbom).to eq ["libquicktime"]
    end

    it "suppresses via patches when the scanned keg matches the current recipe" do
      allow(libquicktime).to receive_messages(
        any_installed_prefix:  Pathname("/nonexistent"),
        any_installed_version: libquicktime.pkg_version,
        installed_kegs:        [instance_double(Keg, version: libquicktime.pkg_version)],
      )
      allow(Homebrew::Vulns::OSV).to receive(:query_batch).and_return([[{ "id" => "CVE-2016-2399" }]])

      results = described_class.new([libquicktime]).scan

      expect(results.findings.first.patched.map(&:id)).to eq ["CVE-2016-2399"]
    end

    it "suppresses via patches when the formula is not installed at all" do
      allow(libquicktime).to receive(:installed_kegs).and_return([])
      allow(Homebrew::Vulns::OSV).to receive(:query_batch).and_return([[{ "id" => "CVE-2016-2399" }]])

      results = described_class.new([libquicktime]).scan

      expect(results.findings.first.patched.map(&:id)).to eq ["CVE-2016-2399"]
    end

    context "when an outdated keg is installed" do
      let(:installed_prefix) { TEST_FIXTURE_DIR/"vulns" }

      before do
        allow(act).to receive_messages(
          any_installed_prefix:  installed_prefix,
          any_installed_version: PkgVersion.parse("0.2.80"),
          installed_kegs:        [instance_double(Keg, version: PkgVersion.parse("0.2.80"))],
        )
      end

      it "queries OSV using the installed keg's SBOM source URL, not the current formula" do
        queried = nil
        allow(Homebrew::Vulns::OSV).to receive(:query_batch) do |packages|
          queried = packages
          Array.new(packages.size) { [] }
        end

        described_class.new([act]).scan

        expect(queried).to eq [{ repo_url: "https://github.com/nektos/act", version: "v0.2.80" }]
      end

      it "reports the installed version in findings" do
        allow(Homebrew::Vulns::OSV).to receive(:query_batch).and_return([[{ "id" => "CVE-2024-1111" }]])

        results = described_class.new([act]).scan

        expect(results.findings.first.version).to eq "0.2.80"
        expect(results.findings.first.tag).to eq "v0.2.80"
      end

      it "filters affects_version? against the installed tag" do
        allow(Homebrew::Vulns::OSV).to receive(:query_batch).and_return([[{ "id" => "CVE-2024-1111" }]])
        allow(Homebrew::Vulns::OSV).to receive(:vulnerability).with("CVE-2024-1111").and_return(
          osv_record("CVE-2024-1111",
                     "affected" => [{ "ranges" => [{ "type"   => "SEMVER",
                                                     "events" => [{ "introduced" => "0" },
                                                                  { "fixed" => "0.2.81" }] }] }]),
        )

        results = described_class.new([act]).scan

        expect(results.findings.first.open.map(&:id)).to eq ["CVE-2024-1111"]
      end

      it "falls back to the current formula URL when the keg has no SBOM" do
        allow(act).to receive(:any_installed_prefix).and_return(Pathname("/nonexistent"))
        queried = nil
        allow(Homebrew::Vulns::OSV).to receive(:query_batch) do |packages|
          queried = packages
          Array.new(packages.size) { [] }
        end

        results = described_class.new([act]).scan

        expect(queried).to eq [{ repo_url: "https://github.com/nektos/act", version: "v0.2.84" }]
        expect(results.outdated_without_sbom).to eq ["act"]
      end
    end
  end
end
