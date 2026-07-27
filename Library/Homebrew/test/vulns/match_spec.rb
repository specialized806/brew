# typed: false
# frozen_string_literal: true

require "vulns/match"

RSpec.describe Homebrew::Vulns::Match do
  let(:repology) do
    Homebrew::Vulns::Repology.new({ "meta" => {}, "formulae" => {
      "requests" => { "Debian" => ["requests"], "Alpine" => ["py3-requests"] },
    } })
  end
  let(:cpan_sec) do
    Homebrew::Vulns::CPANSec.new({ "meta" => {}, "dists" => {
      "Image-ExifTool" => { "advisories" => [
        { "id" => "CPANSA-Image-ExifTool-2021-22204", "cves" => ["CVE-2021-22204"],
          "affected_versions" => ["<12.24"], "fixed_versions" => ["12.24"] },
      ] },
    } })
  end
  let(:matcher) { described_class.new(repology:, cpan_sec:) }

  def stub_repology_lookup(result = {})
    allow(Homebrew::Vulns::Repology).to receive(:lookup).and_return(result)
  end

  describe "#identify" do
    it "derives git repo/tag, primary registry package, resources and distro packages" do
      f = formula("requests") do
        T.bind(self, T.class_of(Formula))
        homepage "https://requests.readthedocs.io"
        url "https://files.pythonhosted.org/packages/aa/bb/cc/requests-2.31.0.tar.gz"
        head "https://github.com/psf/requests.git"
        resource "certifi" do
          url "https://files.pythonhosted.org/packages/11/22/33/certifi-2024.2.2.tar.gz"
        end
        resource "vendored-c" do
          url "https://example.com/blob-1.0.tar.gz"
        end
      end

      identity = matcher.identify(f)

      expect(identity.git_repo).to eq "https://github.com/psf/requests"
      expect(identity.git_tag).to eq "2.31.0"
      expect(identity.primary_package.ecosystem).to eq "PyPI"
      expect(identity.primary_package.name).to eq "requests"
      expect(identity.primary_package.version).to eq "2.31.0"
      expect(identity.resource_packages.keys).to eq ["certifi"]
      expect(identity.resource_packages["certifi"].purl).to eq "pkg:pypi/certifi@2024.2.2"
      expect(identity.distro_packages)
        .to eq("Debian" => ["requests"], "Alpine" => ["py3-requests"])
      expect(identity.any?).to be true
    end

    it "falls back to Repology.lookup when the index has no entry" do
      f = formula("newthing") do
        T.bind(self, T.class_of(Formula))
        url "https://example.com/newthing-1.0.tar.gz"
      end
      stub_repology_lookup({ "Debian" => ["newthing"] })

      expect(matcher.identify(f).distro_packages).to eq("Debian" => ["newthing"])
    end

    it "swallows a Repology lookup error to an empty distro map" do
      f = formula("newthing") do
        T.bind(self, T.class_of(Formula))
        url "https://example.com/newthing-1.0.tar.gz"
      end
      allow(Homebrew::Vulns::Repology).to receive(:lookup)
        .and_raise(Homebrew::Vulns::CachedFeed::Error, "boom")

      expect(matcher.identify(f).distro_packages).to eq({})
    end

    it "reports any? false when nothing is derivable" do
      f = formula("mystery") do
        T.bind(self, T.class_of(Formula))
        url "https://example.com/mystery-1.0.tar.gz"
      end
      stub_repology_lookup

      expect(matcher.identify(f).any?).to be false
    end
  end

  describe "#build_osv_queries" do
    def pkg(ecosystem:, name:, version:, purl:)
      Homebrew::Vulns::Identify::RegistryPackage.new(ecosystem:, name:, version:, purl:)
    end

    it "emits GIT, registry (primary + resource) and distro queries with matching evidence" do
      identity = described_class::Identity.new(
        git_repo:          "https://github.com/psf/requests",
        git_tag:           "v2.31.0",
        primary_package:   pkg(ecosystem: "PyPI", name: "requests", version: "2.31.0",
                               purl: "pkg:pypi/requests@2.31.0"),
        resource_packages: { "certifi" => pkg(ecosystem: "PyPI", name: "certifi", version: "2024.2.2",
                                              purl: "pkg:pypi/certifi@2024.2.2") },
        distro_packages:   { "Debian" => ["requests"], "Alpine" => ["py3-requests"] },
      )

      queries = matcher.build_osv_queries(identity)

      expect(queries.map(&:first)).to eq [
        { ecosystem: "GIT", name: "https://github.com/psf/requests", version: "v2.31.0" },
        { ecosystem: "PyPI", name: "requests", version: "2.31.0" },
        { ecosystem: "PyPI", name: "certifi", version: "2024.2.2" },
        { ecosystem: "Debian", name: "requests", version: nil },
        { ecosystem: "Alpine", name: "py3-requests", version: nil },
      ]
      expect(queries.map { |_, e| [e.strategy, e.key, e.resource] }).to eq [
        [:git, "https://github.com/psf/requests", nil],
        [:registry, "pkg:pypi/requests@2.31.0", nil],
        [:registry, "pkg:pypi/certifi@2024.2.2", "certifi"],
        [:distro, "Debian/requests", nil],
        [:distro, "Alpine/py3-requests", nil],
      ]
    end

    it "excludes CPAN packages from OSV queries and omits GIT when no repo derived" do
      identity = described_class::Identity.new(
        git_repo:          nil,
        git_tag:           "13.55",
        primary_package:   pkg(ecosystem: "CPAN", name: "Image-ExifTool", version: "13.55",
                               purl: "pkg:cpan/EXIFTOOL/Image-ExifTool@13.55"),
        resource_packages: { "extra" => pkg(ecosystem: "CPAN", name: "Try-Tiny", version: "0.31",
                                            purl: "pkg:cpan/ETHER/Try-Tiny@0.31") },
        distro_packages:   {},
      )

      expect(matcher.build_osv_queries(identity)).to eq []
    end
  end

  describe "#cpan_advisory_ids" do
    it "returns CVE ids for CPAN primary and resource packages via CPANSec" do
      identity = described_class::Identity.new(
        git_repo:          nil, git_tag: nil,
        primary_package:   Homebrew::Vulns::Identify::RegistryPackage.new(
          ecosystem: "CPAN", name: "Image-ExifTool", version: "12.00",
          purl: "pkg:cpan/EXIFTOOL/Image-ExifTool@12.00"
        ),
        resource_packages: {}, distro_packages: {}
      )

      ids = matcher.cpan_advisory_ids(identity)

      expect(ids.map(&:first)).to eq ["CVE-2021-22204"]
      expect(ids.first.last.strategy).to eq :cpansa
    end
  end

  describe "#advisories_for" do
    let(:exiftool) do
      formula("exiftool") do
        T.bind(self, T.class_of(Formula))
        url "https://cpan.metacpan.org/authors/id/E/EX/EXIFTOOL/Image-ExifTool-12.00.tar.gz"
        head "https://github.com/exiftool/exiftool.git"
      end
    end

    before { stub_repology_lookup({ "Debian" => ["libimage-exiftool-perl"] }) }

    it "queries every strategy in one batch, fetches full records, and dedups by CVE alias" do
      expect(Homebrew::Vulns::OSV).to receive(:query_batch).with(
        [
          { ecosystem: "GIT", name: "https://github.com/exiftool/exiftool", version: "12.00" },
          { ecosystem: "Debian", name: "libimage-exiftool-perl", version: nil },
        ],
      ).and_return(
        [
          [{ "id" => "CVE-2021-22204" }],
          [{ "id" => "DSA-4910-1" }, { "id" => "DSA-0000-0" }],
        ],
      )
      allow(Homebrew::Vulns::OSV).to receive(:vulnerability).with("CVE-2021-22204").and_return(
        { "id" => "CVE-2021-22204", "aliases" => ["GHSA-xxxx-yyyy-zzzz"] },
      )
      allow(Homebrew::Vulns::OSV).to receive(:vulnerability).with("DSA-4910-1").and_return(
        { "id" => "DSA-4910-1", "aliases" => ["CVE-2021-22204"] },
      )
      allow(Homebrew::Vulns::OSV).to receive(:vulnerability).with("DSA-0000-0").and_return(
        { "id" => "DSA-0000-0", "aliases" => [] },
      )

      hits = matcher.advisories_for(exiftool)

      expect(hits.map(&:canonical_id).sort).to eq ["CVE-2021-22204", "DSA-0000-0"]
      merged = hits.find { |h| h.canonical_id == "CVE-2021-22204" }
      expect(merged.strategy).to eq :git
      expect(merged.evidence.map(&:strategy)).to eq [:git, :cpansa, :distro]
      expect(merged.vulnerability.id).to eq "CVE-2021-22204"
      expect(hits.find { |h| h.canonical_id == "DSA-0000-0" }.strategy).to eq :distro
    end

    it "drops ids whose full record cannot be fetched" do
      allow(Homebrew::Vulns::OSV).to receive(:query_batch).and_return(
        [[{ "id" => "CVE-9999-0000" }], []],
      )
      allow(Homebrew::Vulns::OSV).to receive(:vulnerability)
        .and_raise(Homebrew::Vulns::OSV::ApiError, "404")

      expect(matcher.advisories_for(exiftool)).to eq []
    end

    it "returns [] without hitting OSV when nothing is identifiable" do
      f = formula("mystery") do
        T.bind(self, T.class_of(Formula))
        url "https://example.com/mystery-1.0.tar.gz"
      end
      stub_repology_lookup
      expect(Homebrew::Vulns::OSV).not_to receive(:query_batch)

      expect(matcher.advisories_for(f)).to eq []
    end

    it "caches OSV.vulnerability lookups across calls" do
      allow(Homebrew::Vulns::OSV).to receive(:query_batch)
        .and_return([[{ "id" => "CVE-2021-22204" }], []])
      expect(Homebrew::Vulns::OSV).to receive(:vulnerability).once
        .and_return({ "id" => "CVE-2021-22204" })

      matcher.advisories_for(exiftool)
      matcher.advisories_for(exiftool)
    end
  end

  describe described_class::Hit do
    def vuln(id, aliases: [])
      Homebrew::Vulns::Vulnerability.new({ "id" => id, "aliases" => aliases })
    end

    def ev(strategy, key: "k")
      Homebrew::Vulns::Match::Evidence.new(strategy:, key:)
    end

    it "sorts evidence by descending strategy precision and reports the highest as #strategy" do
      hit = described_class.new(vulnerability: vuln("CVE-1"),
                                evidence:      [ev(:distro), ev(:git), ev(:registry)])
      expect(hit.evidence.map(&:strategy)).to eq [:git, :registry, :distro]
      expect(hit.strategy).to eq :git
    end

    it "uses the lowest CVE alias as canonical_id, or the record id when there is none" do
      expect(described_class.new(vulnerability: vuln("GHSA-x", aliases: ["CVE-2024-2", "CVE-2024-1"]),
                                 evidence:      [ev(:git)]).canonical_id).to eq "CVE-2024-1"
      expect(described_class.new(vulnerability: vuln("GHSA-y"),
                                 evidence:      [ev(:git)]).canonical_id).to eq "GHSA-y"
    end

    it "rejects empty evidence" do
      expect { described_class.new(vulnerability: vuln("CVE-1"), evidence: []) }
        .to raise_error(ArgumentError)
    end
  end
end
