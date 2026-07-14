# typed: false
# frozen_string_literal: true

require "cmd/shared_examples/args_parse"
require "dev-cmd/generate-vulns-advisories"

RSpec.describe Homebrew::DevCmd::GenerateVulnsAdvisories do
  it_behaves_like "parseable arguments"

  it "writes advisories for core formulae with security patch resolves" do
    nvi = formula("nvi") do
      url "https://deb.debian.org/debian/pool/main/n/nvi/nvi_1.81.6.orig.tar.gz"
      version "1.81.6"
      revision 6
      patch do
        url "https://deb.debian.org/debian/pool/main/n/nvi/nvi_1.81.6-17.debian.tar.xz"
        sha256 "abc"
        resolves "CVE-2015-2305"
      end
    end
    plain = formula("plain") { url "https://example.com/plain-1.0.tar.gz" }
    [nvi, plain].each do |f|
      allow(f).to receive(:to_hash_with_variations)
        .and_return({ "patches" => f.serialized_patches, "variations" => {} })
    end

    core_tap = instance_double(CoreTap, installed?: true, name: "homebrew/core", formula_names: ["nvi", "plain"])
    allow(CoreTap).to receive(:instance).and_return(core_tap)
    allow(Formulary).to receive(:enable_factory_cache!)
    allow(Formulary).to receive(:factory).with("nvi").and_return(nvi)
    allow(Formulary).to receive(:factory).with("plain").and_return(plain)
    allow(Homebrew::Vulns::OSV).to receive(:vulnerability).and_return({})

    Dir.mktmpdir do |dir|
      out = "#{dir}/advisories"
      described_class.new([out]).run

      files = Dir.children(out).sort
      expect(files).to eq ["BREW-nvi-CVE-2015-2305.json"]

      record = JSON.parse(File.read("#{out}/BREW-nvi-CVE-2015-2305.json"))
      expect(record["affected"][0]["package"]["ecosystem"]).to eq "Homebrew"
      expect(record["affected"][0]["ranges"][0]["events"][1]).to eq({ "fixed" => "1.81.6_6" })
    end
  end

  it "writes nothing with --dry-run" do
    nvi = formula("nvi") do
      url "https://example.com/nvi-1.81.6.tar.gz"
      patch do
        url "https://example.com/fix.patch"
        sha256 "abc"
        resolves "CVE-2015-2305"
      end
    end
    allow(nvi).to receive(:to_hash_with_variations)
      .and_return({ "patches" => nvi.serialized_patches, "variations" => {} })

    core_tap = instance_double(CoreTap, installed?: true, name: "homebrew/core", formula_names: ["nvi"])
    allow(CoreTap).to receive(:instance).and_return(core_tap)
    allow(Formulary).to receive(:enable_factory_cache!)
    allow(Formulary).to receive(:factory).with("nvi").and_return(nvi)

    Dir.mktmpdir do |dir|
      out = "#{dir}/nonexistent"
      expect(Homebrew::Vulns::OSV).not_to receive(:vulnerability)
      expect { described_class.new(["--dry-run", out]).run }
        .to output(/^BREW-nvi-CVE-2015-2305$/).to_stdout
      expect(Dir.exist?(out)).to be false
    end
  end

  describe "#all_variation_patches" do
    subject(:cmd) { described_class.new(["out"]) }

    it "unions base patches with every variation's patches, deduplicated" do
      f = instance_double(
        Formula,
        to_hash_with_variations: {
          "patches"    => [{ "url" => "a" }, { "url" => "b" }],
          "variations" => {
            arm64_linux:  { "patches" => [{ "url" => "a" }, { "url" => "linux-only" }] },
            x86_64_linux: { "name" => "irrelevant" },
          },
        },
      )

      expect(cmd.all_variation_patches(f)).to eq [{ "url" => "a" }, { "url" => "b" }, { "url" => "linux-only" }]
    end

    it "returns base patches when there are no variations" do
      f = instance_double(
        Formula,
        to_hash_with_variations: { "patches" => [{ "url" => "a" }], "variations" => {} },
      )

      expect(cmd.all_variation_patches(f)).to eq [{ "url" => "a" }]
    end
  end
end
