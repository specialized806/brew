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
end
