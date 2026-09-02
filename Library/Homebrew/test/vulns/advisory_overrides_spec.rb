# typed: true
# frozen_string_literal: true

require "vulns/advisory_overrides"

RSpec.describe Homebrew::Vulns::AdvisoryOverrides do
  it "loads formula skips and candidate-specific state and fix corrections" do
    overrides = described_class.new({
      "linux-headers" => { "skip" => true },
      "safety"        => { "advisories" => {
        "CVE-2026-81726" => { "range_state" => "affected", "upstream_fixed_in" => nil },
      } },
    })

    expect(overrides.skip_formula?("linux-headers")).to be true
    expect(overrides.skip_formula?("safety")).to be false
    entry = overrides.advisory_override("safety", ["PYSEC-2026-1", "CVE-2026-81726"])
    expect(entry).to have_attributes(state: :affected, fixed_in: nil, fixed_in_overridden: true)
  end

  it "rejects unknown fields so misspelled corrections do not silently fail" do
    data = { "safety" => { "advisories" => {
      "CVE-2026-81726" => { "range_status" => "affected" },
    } } }

    expect { described_class.new(data) }
      .to raise_error(Homebrew::Vulns::AdvisoryOverrides::Error, /unknown key.*range_status/)
  end

  it "rejects a non-mapping root instead of disabling every override" do
    ["false\n", "", "---\n"].each do |yaml|
      Tempfile.create(["advisory-overrides", ".yml"]) do |file|
        file.write(yaml)
        file.flush
        expect { described_class.from_file(Pathname(file.path)) }
          .to raise_error(Homebrew::Vulns::AdvisoryOverrides::Error, /top level must be a mapping/)
      end
    end
  end

  it "rejects YAML aliases and tagged objects" do
    [
      "shared: &shared\n  skip: true\ncopy: *shared\n",
      "--- !ruby/object:Object {}\n",
    ].each do |yaml|
      Tempfile.create(["advisory-overrides", ".yml"]) do |file|
        file.write(yaml)
        file.flush
        expect { described_class.from_file(Pathname(file.path)) }
          .to raise_error(Homebrew::Vulns::AdvisoryOverrides::Error)
      end
    end
  end
end
