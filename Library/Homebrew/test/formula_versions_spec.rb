# typed: true
# frozen_string_literal: true

require "formula_versions"

RSpec.describe FormulaVersions do
  it "loads historical formulae that use legacy bottle syntax" do
    current = formula("legacy-bottle") do
      T.bind(self, T.class_of(Formula))
      url "https://brew.sh/legacy-bottle-2.0.tar.gz"
    end
    versions = described_class.new(current)
    digest = "a" * 64
    contents = <<~RUBY
      # frozen_string_literal: true

      class LegacyBottle < Formula
        desc "legacy".frozen?.to_s
        url "https://brew.sh/legacy-bottle-1.0.tar.gz"

        bottle do
          cellar :any_skip_relocation
          sha256 "#{digest}" => :big_sur
        end
      end
    RUBY
    allow(versions).to receive(:file_contents_at_revision).and_return(contents)

    result = versions.formula_at_revision("abc123") do |historical|
      tag = Utils::Bottles::Tag.from_symbol(:big_sur)
      tag_spec = historical.bottle_specification.tag_specification_for(tag)
      [historical.bottle_specification.class, historical.desc, historical.pkg_version.to_s,
       tag_spec&.checksum&.hexdigest, tag_spec&.cellar]
    end

    expect(result).to eq [FormulaVersions::LegacyBottleSpecification, "true", "1.0", digest, :any_skip_relocation]
  end

  it "loads historical formulae that use current bottle syntax" do
    digest = "b" * 64
    current = formula("current-bottle") do
      T.bind(self, T.class_of(Formula))
      url "https://brew.sh/current-bottle-2.0.tar.gz"

      bottle do
        sha256 cellar: :any, big_sur: digest
      end
    end
    versions = described_class.new(current)
    contents = <<~RUBY
      class CurrentBottle < Formula
        url "https://brew.sh/current-bottle-2.0.tar.gz"

        bottle do
          sha256 cellar: :any, big_sur: "#{digest}"
        end
      end
    RUBY
    allow(versions).to receive(:file_contents_at_revision).and_return(contents)

    result = versions.formula_at_revision("abc123") do |historical|
      tag = Utils::Bottles::Tag.from_symbol(:big_sur)
      tag_spec = historical.bottle_specification.tag_specification_for(tag)
      [historical.bottle_specification.class, tag_spec&.checksum&.hexdigest, tag_spec&.cellar,
       historical.bottle_specification == current.bottle_specification]
    end

    expect(result).to eq [FormulaVersions::LegacyBottleSpecification, digest, :any, true]
  end

  it "preserves historical source line numbers" do
    current = formula("source-lines") do
      T.bind(self, T.class_of(Formula))
      url "https://brew.sh/source-lines-2.0.tar.gz"
    end
    versions = described_class.new(current)
    contents = <<~RUBY
      class SourceLines < Formula
        url "https://brew.sh/source-lines-1.0.tar.gz"
      end
    RUBY
    allow(versions).to receive(:file_contents_at_revision).and_return(contents)
    loaded_contents = T.let("", String)
    allow(Formulary).to receive(:from_contents) do |_name, _path, loaded, **_options|
      loaded_contents = loaded
      current
    end

    versions.formula_at_revision("abc123") { nil }

    expect(loaded_contents.lines.index { |line| line.include?("class SourceLines") }).to eq 0
  end

  it "loads historical sources with embedded documentation" do
    current = formula("embedded-docs") do
      T.bind(self, T.class_of(Formula))
      url "https://brew.sh/embedded-docs-2.0.tar.gz"
    end
    versions = described_class.new(current)
    contents = <<~RUBY
      =begin
      Historical documentation.
      =end
      class EmbeddedDocs < Formula
        url "https://brew.sh/embedded-docs-1.0.tar.gz"
      end
    RUBY
    allow(versions).to receive(:file_contents_at_revision).and_return(contents)

    result = versions.formula_at_revision("abc123") { |historical| historical.class.superclass }

    expect(result).to eq described_class.legacy_formula_class
  end

  describe "#formula_at_revision error handling" do
    subject(:versions) { described_class.new(current) }

    let(:current) do
      formula("history-errors") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/history-errors-2.0.tar.gz"
      end
    end

    before do
      allow(versions).to receive(:file_contents_at_revision).and_return("")
    end

    it "skips unexpected standard errors while loading" do
      allow(Formulary).to receive(:from_contents).and_raise("boom")

      expect(versions.formula_at_revision("abc123") { raise "unreachable" }).to be_nil
    end

    it "skips unexpected script errors while loading" do
      allow(Formulary).to receive(:from_contents).and_raise(NotImplementedError, "boom")

      expect(versions.formula_at_revision("abc123") { raise "unreachable" }).to be_nil
    end

    it "does not skip macOS version errors while loading" do
      allow(Formulary).to receive(:from_contents).and_raise(MacOSVersion::Error.new(:unsupported))

      expect { versions.formula_at_revision("abc123") { raise "unreachable" } }
        .to raise_error(MacOSVersion::Error)
    end

    it "does not skip untrusted taps while loading" do
      allow(Formulary).to receive(:from_contents).and_raise(Homebrew::UntrustedTapError, "boom")

      expect { versions.formula_at_revision("abc123") { raise "unreachable" } }
        .to raise_error(Homebrew::UntrustedTapError, "boom")
    end

    it "does not skip disabled formula loading" do
      allow(Homebrew::EnvConfig).to receive(:disable_load_formula?).and_return(true)

      expect { versions.formula_at_revision("abc123") { raise "unreachable" } }
        .to raise_error(RuntimeError, /HOMEBREW_DISABLE_LOAD_FORMULA/)
    end

    it "does not skip errors from the history consumer" do
      allow(Formulary).to receive(:from_contents).and_return(current)

      expect { versions.formula_at_revision("abc123") { raise ArgumentError, "boom" } }
        .to raise_error(ArgumentError, "boom")
    end

    it "does not skip process exits while loading" do
      allow(Formulary).to receive(:from_contents).and_raise(SystemExit, "boom")

      expect { versions.formula_at_revision("abc123") { raise "unreachable" } }
        .to raise_error(SystemExit, "boom")
    end
  end
end
