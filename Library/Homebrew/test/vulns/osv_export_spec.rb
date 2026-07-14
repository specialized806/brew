# typed: false
# frozen_string_literal: true

require "vulns/osv_export"

RSpec.describe Homebrew::Vulns::OsvExport do
  let(:now) { Time.utc(2026, 6, 28, 12, 0, 0) }

  let(:nvi) do
    formula("nvi") do
      url "https://deb.debian.org/debian/pool/main/n/nvi/nvi_1.81.6.orig.tar.gz"
      version "1.81.6"
      revision 6
      patch :p0 do
        file "Patches/nvi/patch-common__db.h"
      end
      patch do
        url "https://deb.debian.org/debian/pool/main/n/nvi/nvi_1.81.6-17.debian.tar.xz"
        sha256 "abc"
        type :backport
        apply "patches/31regex_heap_overflow.patch"
        resolves "CVE-2015-2305"
      end
    end
  end

  let(:libquicktime) do
    formula("libquicktime") do
      url "https://downloads.sourceforge.net/project/libquicktime/libquicktime-1.2.4.tar.gz"
      revision 5
      patch do
        url "https://deb.debian.org/debian/pool/main/libq/libquicktime/libquicktime_1.2.4-12.debian.tar.xz"
        sha256 "abc"
        resolves "CVE-2016-2399", "CVE-2017-9122"
      end
    end
  end

  describe ".record_for" do
    it "builds a minimal record without upstream data" do
      record = described_class.record_for(nvi, "CVE-2015-2305", now:)

      expect(record[:schema_version]).to eq "1.7.3"
      expect(record[:id]).to eq "BREW-nvi-CVE-2015-2305"
      expect(record[:modified]).to eq "2026-06-28T12:00:00Z"
      expect(record[:upstream]).to eq ["CVE-2015-2305"]
      expect(record).not_to have_key(:summary)
      expect(record).not_to have_key(:references)
    end

    it "populates affected package and range" do
      affected = described_class.record_for(nvi, "CVE-2015-2305", now:)[:affected].first

      expect(affected[:package][:ecosystem]).to eq "Homebrew"
      expect(affected[:package][:name]).to eq "nvi"
      expect(affected[:package][:purl]).to eq "pkg:brew/nvi"
      expect(affected[:ranges].first[:events]).to eq [{ introduced: "0" }, { fixed: "1.81.6_6" }]
    end

    it "lists only the patches that resolve the given id in ecosystem_specific" do
      eco = described_class.record_for(nvi, "CVE-2015-2305", now:).dig(:affected, 0, :ecosystem_specific)

      expect(eco[:fix]).to eq "patch"
      expect(eco[:patches]).to eq [
        {
          type:  "backport",
          url:   "https://deb.debian.org/debian/pool/main/n/nvi/nvi_1.81.6-17.debian.tar.xz",
          apply: ["patches/31regex_heap_overflow.patch"],
        },
      ]
    end

    it "emits file for local patches and drops entries with no locator" do
      f = formula("x") do
        url "https://example.com/x-1.0.tar.gz"
        patch do
          file "Patches/x/fix.patch"
          resolves "CVE-2024-0001"
        end
        patch do
          url "https://example.com/x/fix.patch"
          sha256 "abc"
          resolves "CVE-2024-0001"
        end
      end
      patches = f.serialized_patches + [{ "resolves" => [{ "type" => "security", "id" => "CVE-2024-0001" }] }]

      refs = described_class.record_for(f, "CVE-2024-0001", patches:, now:)
                            .dig(:affected, 0, :ecosystem_specific, :patches)

      expect(refs).to eq [{ file: "Patches/x/fix.patch" }, { url: "https://example.com/x/fix.patch" }]
    end

    it "reads the given patches list rather than the formula's own serialized_patches" do
      f = formula("x") { url "https://example.com/x-1.0.tar.gz" }
      linux_only = [{ "url"      => "https://example.com/linux.patch",
                      "resolves" => [{ "type" => "security", "id" => "CVE-2024-0003" }] }]

      eco = described_class.record_for(f, "CVE-2024-0003", patches: linux_only, now:)
                           .dig(:affected, 0, :ecosystem_specific)

      expect(eco[:patches]).to eq [{ url: "https://example.com/linux.patch" }]
    end

    it "merges upstream summary, details, aliases, severity and references" do
      upstream = {
        "summary"    => "Integer overflow in regcomp",
        "details"    => "Long description.",
        "aliases"    => ["GHSA-aaaa-bbbb-cccc"],
        "severity"   => [{ "type" => "CVSS_V3", "score" => "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:H" }],
        "references" => [{ "type" => "ADVISORY", "url" => "https://bugs.debian.org/778412" }],
      }

      record = described_class.record_for(nvi, "CVE-2015-2305", upstream:, now:)

      expect(record[:summary]).to eq "Integer overflow in regcomp"
      expect(record[:details]).to eq "Long description."
      expect(record[:upstream]).to eq ["CVE-2015-2305", "GHSA-aaaa-bbbb-cccc"]
      expect(record[:severity]).to eq upstream["severity"]
      expect(record[:references]).to eq upstream["references"]
    end

    it "percent-encodes @ in the purl but not the package name" do
      glibc = formula("glibc@2.13") do
        url "https://ftp.gnu.org/gnu/glibc/glibc-2.13.tar.gz"
        patch do
          url "https://example.com/fix.patch"
          sha256 "abc"
          resolves "CVE-2024-2961"
        end
      end

      affected = described_class.record_for(glibc, "CVE-2024-2961", now:).dig(:affected, 0)

      expect(affected[:package][:purl]).to eq "pkg:brew/glibc%402.13"
      expect(affected[:package][:name]).to eq "glibc@2.13"
    end

    it "percent-encodes + in the purl" do
      libsigcxx = formula("libsigc++") do
        url "https://download.gnome.org/sources/libsigc++/3.6/libsigc++-3.6.0.tar.xz"
        patch do
          url "https://example.com/fix.patch"
          sha256 "abc"
          resolves "CVE-2024-0002"
        end
      end

      affected = described_class.record_for(libsigcxx, "CVE-2024-0002", now:).dig(:affected, 0)

      expect(affected[:package][:purl]).to eq "pkg:brew/libsigc%2B%2B"
      expect(affected[:package][:name]).to eq "libsigc++"
    end

    it "omits the revision suffix when revision is zero" do
      f = formula("x") do
        url "https://example.com/x-1.0.tar.gz"
        patch do
          url "https://example.com/fix.patch"
          sha256 "abc"
          resolves "CVE-2024-0001"
        end
      end

      events = described_class.record_for(f, "CVE-2024-0001", now:).dig(:affected, 0, :ranges, 0, :events)

      expect(events[1]).to eq({ fixed: "1.0" })
    end
  end

  describe ".run" do
    it "writes one file per (formula, CVE) pair" do
      allow(Homebrew::Vulns::OSV).to receive(:vulnerability).and_return({})

      Dir.mktmpdir do |dir|
        annotated = [[nvi, nvi.serialized_patches], [libquicktime, libquicktime.serialized_patches]]
        written = described_class.run(annotated, dir, now:)

        expect(written.map { |p| File.basename(p) }.sort).to eq [
          "BREW-libquicktime-CVE-2016-2399.json",
          "BREW-libquicktime-CVE-2017-9122.json",
          "BREW-nvi-CVE-2015-2305.json",
        ]
        written.each do |p|
          record = JSON.parse(File.read(p))
          expect(record["affected"][0]["package"]["ecosystem"]).to eq "Homebrew"
        end
      end
    end

    it "still writes a record when the upstream fetch fails" do
      allow(Homebrew::Vulns::OSV).to receive(:vulnerability).and_raise(Homebrew::Vulns::OSV::ApiError)

      Dir.mktmpdir do |dir|
        written = described_class.run([[nvi, nvi.serialized_patches]], dir, now:)

        expect(written.size).to eq 1
        record = JSON.parse(File.read(written.first))
        expect(record["upstream"]).to eq ["CVE-2015-2305"]
        expect(record).not_to have_key("summary")
      end
    end
  end
end
