# frozen_string_literal: true

require "api"

RSpec.describe Homebrew::API::CaskStruct do
  describe "::from_hash" do
    it "constructs a valid struct from a hash with all field types" do
      hash = {
        "sha256"               => "abc123",
        "version"              => "1.0.0",
        "ruby_source_checksum" => { sha256: "def456" },
        "names"                => ["Test Cask"],
        "desc"                 => "A test cask",
        "homepage"             => "https://example.com",
        "auto_updates"         => true,
        "languages"            => ["en"],
        "url_args"             => ["https://example.com/file.dmg"],
        "url_kwargs"           => { verified: "example.com/" },
        "conflicts_with_args"  => { cask: ["other-cask"] },
        "depends_on_args"      => { macos: ">= :catalina" },
        "container_args"       => { type: :zip },
        "deprecate_args"       => { date: "2025-01-01", because: :discontinued },
        "raw_artifacts"        => [[:app, ["Test.app"], {}, nil]],
        "raw_caveats"          => "Requires restart.",
      }

      struct = described_class.from_hash(hash)

      expect(struct.sha256).to eq("abc123")
      expect(struct.version).to eq("1.0.0")
      expect(struct.names).to eq(["Test Cask"])
      expect(struct.desc).to eq("A test cask")
      expect(struct.homepage).to eq("https://example.com")
      expect(struct.auto_updates).to be(true)
      expect(struct.languages).to eq(["en"])
    end

    it "ignores unknown/extra keys" do
      hash = {
        "sha256"               => "abc123",
        "version"              => "1.0.0",
        "ruby_source_checksum" => { sha256: "def456" },
        "totally_unknown_key"  => "should be ignored",
        "another_unknown"      => 42,
      }

      expect { described_class.from_hash(hash) }.not_to raise_error
    end
  end

  describe "predicate methods" do
    it "defaults all predicates to false for a minimal struct" do
      struct = described_class.new(
        sha256:               "abc123",
        version:              "1.0.0",
        ruby_source_checksum: { sha256: "def456" },
      )

      Homebrew::API::CaskStruct::PREDICATES.each do |predicate|
        expect(struct.send(:"#{predicate}?")).to be(false),
                                                 "expected #{predicate}? to default to false"
      end
    end

    it "returns true when the corresponding _present field is set" do
      present_fields = Homebrew::API::CaskStruct::PREDICATES.to_h do |predicate|
        [:"#{predicate}_present", true]
      end

      struct = described_class.new(
        sha256:               "abc123",
        version:              "1.0.0",
        ruby_source_checksum: { sha256: "def456" },
        **present_fields,
      )

      Homebrew::API::CaskStruct::PREDICATES.each do |predicate|
        expect(struct.send(:"#{predicate}?")).to be(true),
                                                 "expected #{predicate}? to be true"
      end
    end
  end

  describe "#artifacts" do
    it "replaces placeholders in artifact arguments" do
      struct = described_class.new(
        sha256:               "abc123",
        version:              "1.0.0",
        ruby_source_checksum: { sha256: "def456" },
        raw_artifacts:        [[:app, ["#{HOMEBREW_CASK_APPDIR_PLACEHOLDER}/Test.app"], {}, nil]],
      )

      result = struct.artifacts(appdir: "/Applications")

      expect(result).to eq([[:app, ["/Applications/Test.app"], {}, nil]])
    end
  end

  describe "#caveats" do
    it "replaces placeholders in caveats string" do
      struct = described_class.new(
        sha256:               "abc123",
        version:              "1.0.0",
        ruby_source_checksum: { sha256: "def456" },
        raw_caveats:          "Installed to #{HOMEBREW_PREFIX_PLACEHOLDER}/bin",
      )

      result = struct.caveats(appdir: "/Applications")

      expect(result).to eq("Installed to #{HOMEBREW_PREFIX}/bin")
    end

    it "returns nil when raw_caveats is nil" do
      struct = described_class.new(
        sha256:               "abc123",
        version:              "1.0.0",
        ruby_source_checksum: { sha256: "def456" },
      )

      expect(struct.caveats(appdir: "/Applications")).to be_nil
    end
  end
end
