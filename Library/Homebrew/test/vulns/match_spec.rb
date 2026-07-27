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
      expect(identity.identifiable?).to be true
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

    it "reports identifiable? false when nothing is derivable" do
      f = formula("mystery") do
        T.bind(self, T.class_of(Formula))
        url "https://example.com/mystery-1.0.tar.gz"
      end
      stub_repology_lookup

      expect(matcher.identify(f).identifiable?).to be false
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

  describe "#to_brew_record and helpers" do
    let(:requests) do
      formula("requests") do
        T.bind(self, T.class_of(Formula))
        url "https://files.pythonhosted.org/packages/aa/bb/cc/requests-2.31.0.tar.gz"
        resource "certifi" do
          url "https://files.pythonhosted.org/packages/11/22/33/certifi-2024.2.2.tar.gz"
        end
      end
    end
    let(:now) { Time.utc(2026, 7, 27, 12, 0, 0) }

    def make_hit(id:, aliases: [], fixed: [], strategy: :registry, key: "pkg:pypi/requests@2.31.0",
                 resource: nil, extra_evidence: [])
      affected = fixed.any? ? [{ "ranges" => [{ "events" => fixed.map { |f| { "fixed" => f } } }] }] : []
      vuln = Homebrew::Vulns::Vulnerability.new({ "id" => id, "aliases" => aliases, "affected" => affected,
                                                  "summary" => "s", "details" => "d" })
      described_class::Hit.new(
        vulnerability: vuln,
        evidence:      [described_class::Evidence.new(strategy:, key:, resource:), *extra_evidence],
      )
    end

    describe "#upstream_fix_shipped?" do
      it "is true when the subject version is at or past the lowest upstream fixed version" do
        hit = make_hit(id: "CVE-1", fixed: ["2.28.1", "2.30.0"])
        expect(matcher.upstream_fix_shipped?(requests.version, hit)).to be true
      end

      it "is false when the subject version is below every upstream fixed version" do
        hit = make_hit(id: "CVE-1", fixed: ["2.32.0"])
        expect(matcher.upstream_fix_shipped?(requests.version, hit)).to be false
      end

      it "is false when there are no fixed versions or no subject version" do
        expect(matcher.upstream_fix_shipped?(requests.version, make_hit(id: "CVE-1", fixed: []))).to be false
        expect(matcher.upstream_fix_shipped?(nil, make_hit(id: "CVE-1", fixed: ["1.0"]))).to be false
      end

      it "ignores distro-strategy fixed versions" do
        hit = make_hit(id: "CVE-1", fixed: ["1:2.28.1-1+deb12u1"], strategy: :distro, key: "Debian/requests")
        expect(matcher.comparable_fix_threshold(hit)).to be_nil
        expect(matcher.upstream_fix_shipped?(requests.version, hit)).to be false
      end

      it "strips a leading v from upstream fixed versions before comparing" do
        hit = make_hit(id: "CVE-1", fixed: ["v2.28.1"])
        expect(matcher.comparable_fix_threshold(hit)).to eq Version.new("2.28.1")
      end
    end

    describe "#subject_version" do
      it "returns the resource's pinned version for a resource hit" do
        hit = make_hit(id: "CVE-1", key: "pkg:pypi/certifi@2024.2.2", resource: "certifi")
        expect(matcher.subject_version(requests, hit)).to eq Version.new("2024.2.2")
      end

      it "returns the formula version for a primary hit" do
        expect(matcher.subject_version(requests, make_hit(id: "CVE-1"))).to eq Version.new("2.31.0")
      end

      it "returns nil when the resource no longer exists in the formula" do
        hit = make_hit(id: "CVE-1", resource: "gone")
        expect(matcher.subject_version(requests, hit)).to be_nil
      end
    end

    describe "#first_fixed_version" do
      def stub_history(versions_newest_first)
        fv = instance_double(FormulaVersions)
        revs = versions_newest_first.each_with_index.map { |_, i| ["r#{i}", "Formula/r/requests.rb"] }
        allow(fv).to receive(:rev_list) { |_, &b| revs.each { |rev, entry| b.call(rev, entry) } }
        versions_newest_first.each_with_index do |v, i|
          old = if v
            formula("requests") do
              T.bind(self, T.class_of(Formula))
              url "https://files.pythonhosted.org/packages/aa/bb/cc/requests-#{v}.tar.gz"
            end
          end
          allow(fv).to receive(:formula_at_revision).with("r#{i}", anything) do |&b|
            old && b.call(old)
          end
        end
        allow(FormulaVersions).to receive(:new).and_return(fv)
      end

      it "returns the pkg_version at the oldest revision still at or past the threshold" do
        stub_history(["2.31.0", "2.30.0", "2.28.1", "2.28.0", "2.27.0"])
        hit = make_hit(id: "CVE-1", fixed: ["2.28.1"])

        expect(matcher.first_fixed_version(requests, hit)).to eq "2.28.1"
      end

      it "stops at an unloadable revision and returns the last known fixed pkg_version" do
        stub_history(["2.31.0", "2.30.0", nil, "2.28.0"])
        hit = make_hit(id: "CVE-1", fixed: ["2.28.1"])

        expect(matcher.first_fixed_version(requests, hit)).to eq "2.30.0"
      end

      it "returns nil when the current version is not yet fixed" do
        hit = make_hit(id: "CVE-1", fixed: ["2.32.0"])
        expect(FormulaVersions).not_to receive(:new)

        expect(matcher.first_fixed_version(requests, hit)).to be_nil
      end

      it "returns nil for a distro-strategy hit (no comparable threshold)" do
        hit = make_hit(id: "CVE-1", fixed: ["1:2.28.1-1"], strategy: :distro, key: "Debian/requests")
        expect(matcher.first_fixed_version(requests, hit)).to be_nil
      end

      it "caches the rev-list per formula across hits" do
        fv = instance_double(FormulaVersions)
        expect(fv).to receive(:rev_list).once { |_, &b| b.call("r0", "p") }
        allow(fv).to receive(:formula_at_revision).and_return(nil)
        allow(FormulaVersions).to receive(:new).once.and_return(fv)

        matcher.first_fixed_version(requests, make_hit(id: "CVE-1", fixed: ["1.0"]))
        matcher.first_fixed_version(requests, make_hit(id: "CVE-2", fixed: ["1.0"]))
      end
    end

    describe "#to_brew_record" do
      before do
        allow(matcher).to receive(:fetch_vulnerability).and_return(
          { "id" => "CVE-2024-1234", "severity" => [{ "type" => "CVSS_V3", "score" => "..." }],
            "references" => [{ "type" => "ADVISORY", "url" => "https://x" }] },
        )
      end

      it "emits a matched OSV record with fixed=pkg_version when the upstream fix is shipped" do
        hit = make_hit(id: "CVE-2024-1234", aliases: ["GHSA-abcd-efgh-ijkl"], fixed: ["2.28.1"])

        record = matcher.to_brew_record(requests, hit, now:)

        expect(record[:schema_version]).to eq Homebrew::Vulns::OsvExport::SCHEMA_VERSION
        expect(record[:id]).to eq "BREW-requests-CVE-2024-1234"
        expect(record[:published]).to eq "2026-07-27T12:00:00Z"
        expect(record[:upstream]).to eq ["CVE-2024-1234", "GHSA-abcd-efgh-ijkl"]
        expect(record[:summary]).to eq "s"
        expect(record[:severity]).to eq [{ "type" => "CVSS_V3", "score" => "..." }]
        expect(record[:references]).to eq [{ "type" => "ADVISORY", "url" => "https://x" }]

        aff = record[:affected].first
        expect(aff[:package]).to eq(ecosystem: "Homebrew", name: "requests", purl: "pkg:brew/requests")
        expect(aff[:ranges]).to eq [{ type: "ECOSYSTEM", events: [{ introduced: "0" },
                                                                  { fixed: requests.pkg_version.to_s }] }]
        expect(aff[:ecosystem_specific]).to eq(fix: "bump")

        db = record[:database_specific]
        expect(db[:source]).to eq "matched"
        expect(db[:strategy]).to eq "registry"
        expect(db[:confidence]).to eq "high"
        expect(db[:upstream_evidence]).to eq [{ strategy: :registry, key: "pkg:pypi/requests@2.31.0" }]
      end

      it "prefers an explicit first_fixed over the current pkg_version" do
        hit = make_hit(id: "CVE-2024-1234", fixed: ["2.28.1"])

        record = matcher.to_brew_record(requests, hit, first_fixed: "2.28.1_1", now:)

        expect(record.dig(:affected, 0, :ranges, 0, :events)).to eq [{ introduced: "0" }, { fixed: "2.28.1_1" }]
      end

      it "omits the fixed event and sets fix: nil when no upstream fix is shipped" do
        hit = make_hit(id: "CVE-2024-1234", fixed: ["2.32.0"])

        record = matcher.to_brew_record(requests, hit, now:)

        aff = record[:affected].first
        expect(aff[:ranges]).to eq [{ type: "ECOSYSTEM", events: [{ introduced: "0" }] }]
        expect(aff[:ecosystem_specific]).to eq(fix: nil)
      end

      it "records resource name and purl and compares against the resource's pinned version" do
        hit = make_hit(id: "CVE-2024-1234", fixed: ["2024.2.2"], key: "pkg:pypi/certifi@2024.2.2",
                       resource: "certifi")

        record = matcher.to_brew_record(requests, hit, now:)

        expect(record.dig(:affected, 0, :ecosystem_specific))
          .to eq(fix: "bump", resource: "certifi", resource_purl: "pkg:pypi/certifi@2024.2.2")
        expect(record.dig(:affected, 0, :ranges, 0, :events).last).to eq(fixed: requests.pkg_version.to_s)
      end

      it "reports distro strategy at low confidence with all evidence listed" do
        hit = make_hit(id: "CVE-2024-1234", fixed: ["1:2.28.1-1"], strategy: :distro, key: "Debian/requests",
                       extra_evidence: [described_class::Evidence.new(strategy: :distro, key: "Alpine/py3-requests")])

        record = matcher.to_brew_record(requests, hit, now:)

        expect(record.dig(:database_specific, :strategy)).to eq "distro"
        expect(record.dig(:database_specific, :confidence)).to eq "low"
        expect(record.dig(:database_specific, :upstream_evidence))
          .to eq [{ strategy: :distro, key: "Debian/requests" },
                  { strategy: :distro, key: "Alpine/py3-requests" }]
        expect(record.dig(:affected, 0, :ecosystem_specific, :fix)).to be_nil
      end
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
