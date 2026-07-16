# typed: false
# frozen_string_literal: true

require "vulns/cpan_sec"

RSpec.describe Homebrew::Vulns::CPANSec do
  let(:fixture) { TEST_FIXTURE_DIR/"vulns/cpansa.json" }
  let(:cpansa) { described_class.from_file(fixture) }

  describe ".from_file" do
    it "raises Error on unparseable JSON" do
      Dir.mktmpdir do |dir|
        bad = Pathname(dir)/"cpansa.json"
        bad.write "not json"
        expect { described_class.from_file(bad) }
          .to raise_error(described_class::Error, /Failed to parse cpansa\.json/)
      end
    end
  end

  describe "#initialize" do
    it "raises Error when the dists key is missing" do
      expect { described_class.new({ "meta" => {} }) }
        .to raise_error(described_class::Error, /missing 'dists' key/)
    end

    it "raises Error when the top-level value is not a JSON object" do
      expect { described_class.new([]) }.to raise_error(described_class::Error, /not a JSON object/)
      expect { described_class.new(nil) }.to raise_error(described_class::Error, /not a JSON object/)
    end

    it "treats a null or absent meta as an empty hash" do
      expect(described_class.new({ "dists" => {}, "meta" => nil }).meta).to eq({})
      expect(described_class.new({ "dists" => {} }).meta).to eq({})
    end
  end

  describe "#meta" do
    it "returns the upstream build metadata" do
      expect(cpansa.meta).to include("commit" => "abc123", "epoch" => 1784142497)
    end
  end

  describe "#distributions" do
    it "lists all distribution names" do
      expect(cpansa.distributions).to contain_exactly("DBI", "Image-ExifTool")
    end
  end

  describe "#advisories_for" do
    it "returns Advisory structs with all fields populated" do
      first = cpansa.advisories_for("DBI").first
      expect(first).to have_attributes(
        id:                "CPANSA-DBI-2020-01",
        cves:              ["CVE-2020-14393"],
        affected_versions: ["<1.643"],
        fixed_versions:    [">=1.643"],
        severity:          "high",
        description:       "Buffer overflow in DBI.xs.\n",
        references:        ["https://metacpan.org/changes/distribution/DBI"],
        reported:          "2020-09-16",
      )
    end

    it "coerces cves and affected_versions to string arrays and defaults absent optional fields" do
      second = cpansa.advisories_for("DBI")[1]
      expect(second.id).to eq "CPANSA-DBI-2014-01"
      expect(second.cves).to eq ["CVE-2014-10402", "CVE-2014-10401"]
      expect(second.affected_versions).to eq [">=0.64,<1.632"]
      expect(second.description).to be_nil
      expect(second.references).to eq []
    end

    it "returns all advisories for a distribution in file order" do
      expect(cpansa.advisories_for("DBI").map(&:id))
        .to eq ["CPANSA-DBI-2020-01", "CPANSA-DBI-2014-01"]
    end

    it "returns an empty array for an unknown distribution" do
      expect(cpansa.advisories_for("No-Such-Dist")).to eq []
    end

    it "returns frozen advisories" do
      expect(cpansa.advisories_for("Image-ExifTool").first).to be_frozen
    end
  end

  describe ".load" do
    it "reads a fresh cache file without downloading" do
      Dir.mktmpdir do |dir|
        cache = Pathname(dir)
        FileUtils.cp fixture, cache/"cpansa.json"
        expect(Utils::Curl).not_to receive(:curl_download)
        loaded = described_class.load(cache:)
        expect(loaded.distributions).to include "DBI"
      end
    end

    it "downloads to a temp file and atomically replaces a stale cache" do
      Dir.mktmpdir do |dir|
        cache = Pathname(dir)
        stale = cache/"cpansa.json"
        stale.write '{"dists": {}}'
        FileUtils.touch stale, mtime: Time.now - 100_000
        expect(Utils::Curl).to receive(:curl_download) do |*_args, to:|
          expect(to).not_to eq stale
          FileUtils.cp fixture, to
        end
        expect(described_class.load(cache:).distributions).to include "DBI"
        expect(stale.read).to eq fixture.read
        expect(cache.children.map { |c| c.basename.to_s }).to eq ["cpansa.json"]
      end
    end

    it "downloads when the cache file is absent" do
      Dir.mktmpdir do |dir|
        cache = Pathname(dir)
        expect(Utils::Curl).to receive(:curl_download) do |*_args, to:|
          FileUtils.cp fixture, to
        end
        expect(described_class.load(cache:).advisories_for("Image-ExifTool").length).to eq 1
      end
    end

    it "falls back to a stale cache when the download fails, leaving it intact" do
      Dir.mktmpdir do |dir|
        cache = Pathname(dir)
        stale = cache/"cpansa.json"
        FileUtils.cp fixture, stale
        FileUtils.touch stale, mtime: Time.now - 100_000
        original = stale.read
        expect(Utils::Curl).to receive(:curl_download)
          .and_raise(ErrorDuringExecution.new(["curl"], status: 22))
        loaded = nil
        expect { loaded = described_class.load(cache:) }
          .to output(/Failed to refresh cpansa\.json/).to_stderr
        expect(loaded.distributions).to include "DBI"
        expect(stale.read).to eq original
      end
    end

    it "falls back to a stale cache when the fetched file is invalid, leaving it intact" do
      Dir.mktmpdir do |dir|
        cache = Pathname(dir)
        stale = cache/"cpansa.json"
        FileUtils.cp fixture, stale
        FileUtils.touch stale, mtime: Time.now - 100_000
        original = stale.read
        expect(Utils::Curl).to receive(:curl_download) { |*_args, to:| to.write "not json" }
        loaded = nil
        expect { loaded = described_class.load(cache:) }
          .to output(/Failed to refresh cpansa\.json/).to_stderr
        expect(loaded.distributions).to include "DBI"
        expect(stale.read).to eq original
        expect(cache.children).to eq [stale]
      end
    end

    it "raises when the download fails and no cache exists" do
      Dir.mktmpdir do |dir|
        expect(Utils::Curl).to receive(:curl_download)
          .and_raise(ErrorDuringExecution.new(["curl"], status: 6))
        expect { described_class.load(cache: Pathname(dir)) }.to raise_error(ErrorDuringExecution)
      end
    end
  end
end
