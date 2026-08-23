# typed: true
# frozen_string_literal: true

require "cmd/shared_examples/args_parse"
require "dev-cmd/advisory-match"

RSpec.describe Homebrew::DevCmd::AdvisoryMatch do
  let(:requests) do
    formula("requests") do
      T.bind(self, T.class_of(Formula))
      url "https://files.pythonhosted.org/packages/aa/bb/cc/requests-2.31.0.tar.gz"
      head "https://github.com/psf/requests.git"
    end
  end

  before do
    allow(Formulary).to receive(:enable_factory_cache!)
    allow(Homebrew::Vulns::Repology).to receive_messages(
      load:   Homebrew::Vulns::Repology.new({ "meta" => {}, "formulae" => {} }),
      lookup: {},
    )
    allow(Homebrew::Vulns::CPANSec).to receive(:load).and_return(
      Homebrew::Vulns::CPANSec.new({ "meta" => {}, "dists" => {} }),
    )
  end

  it_behaves_like "parseable arguments"

  def cmd_for(*argv, formulae: [requests])
    cmd = described_class.new(argv)
    allow(cmd.args.named).to receive(:to_resolved_formulae).and_return(formulae)
    cmd
  end

  def stub_osv_hit(cve, fixed:)
    allow(Homebrew::Vulns::OSV).to receive(:query_batch).and_return([[{ "id" => cve }], []])
    allow(Homebrew::Vulns::OSV).to receive(:vulnerability).with(cve).and_return(
      { "id" => cve, "summary" => "s",
        "affected" => [{
          "package" => { "ecosystem" => "GIT", "name" => "https://github.com/psf/requests" },
          "ranges"  => [{ "type"   => "ECOSYSTEM",
                          "events" => [{ "introduced" => "0" }, { "fixed" => fixed }] }],
        }] },
    )
  end

  it "writes matched records to --output=<dir> with merge_existing semantics" do
    stub_osv_hit("CVE-2024-1234", fixed: "2.28.1")

    Dir.mktmpdir do |dir|
      expect { cmd_for("requests", "--output", dir, "--no-history").run }
        .to output(/1 records written/).to_stdout

      path = File.join(dir, "BREW-requests-CVE-2024-1234.json")
      record = JSON.parse(File.read(path))
      expect(record.dig("affected", 0, "package"))
        .to eq("ecosystem" => "Homebrew", "name" => "requests", "purl" => "pkg:brew/requests")
      expect(record.dig("affected", 0, "ranges", 0, "events", 1))
        .to eq("fixed" => requests.pkg_version.to_s)
      expect(record.dig("database_specific", "source")).to eq "matched"
      expect(record.dig("database_specific", "strategy")).to eq "git"

      # A second run with the same output should report 0 written / 1 unchanged.
      expect { cmd_for("requests", "--output", dir, "--no-history").run }
        .to output(/0 records written to #{Regexp.escape(dir)} \(1 unchanged, 0 generated/).to_stdout
    end
  end

  it "only walks history for records not already present with --new-history" do
    stub_osv_hit("CVE-2024-1234", fixed: "2.28.1")

    Dir.mktmpdir do |dir|
      path = File.join(dir, "BREW-requests-CVE-2024-1234.json")
      record = {
        "schema_version"    => Homebrew::Vulns::OsvExport::SCHEMA_VERSION,
        "id"                => "BREW-requests-CVE-2024-1234",
        "modified"          => "2026-01-01T00:00:00Z",
        "affected"          => [{
          "package" => { "ecosystem" => "Homebrew", "name" => "requests" },
          "ranges"  => [{ "type" => "ECOSYSTEM", "events" => [
            { "introduced" => "0" }, { "fixed" => "2.28.1" }
          ] }],
        }],
        "database_specific" => { "source" => "matched" },
      }
      File.write(path, JSON.generate(record))

      matcher = Homebrew::Vulns::Match.new
      allow(Homebrew::Vulns::Match).to receive(:new).and_return(matcher)
      expect(matcher).not_to receive(:first_fixed_version)

      expect { cmd_for("requests", "--output", dir, "--new-history").run }
        .to output(/0 history walks/).to_stdout
      expect(JSON.parse(File.read(path)).dig("affected", 0, "ranges", 0, "events", 1))
        .to eq("fixed" => "2.28.1")
    end
  end

  it "uses the historical boundary for a new record with --new-history" do
    stub_osv_hit("CVE-2024-1234", fixed: "2.28.1")
    matcher = Homebrew::Vulns::Match.new
    expect(matcher).to receive(:first_fixed_version).and_return("2.28.1")
    allow(Homebrew::Vulns::Match).to receive(:new).and_return(matcher)

    Dir.mktmpdir do |dir|
      expect { cmd_for("requests", "--output", dir, "--new-history").run }
        .to output(/1 history walks/).to_stdout
      path = File.join(dir, "BREW-requests-CVE-2024-1234.json")
      expect(JSON.parse(File.read(path)).dig("affected", 0, "ranges", 0, "events", 1))
        .to eq("fixed" => "2.28.1")
    end
  end

  it "walks history when an existing matched record has no ranges" do
    stub_osv_hit("CVE-2024-1234", fixed: "2.28.1")
    matcher = Homebrew::Vulns::Match.new
    expect(matcher).to receive(:first_fixed_version).and_return("2.28.1")
    allow(Homebrew::Vulns::Match).to receive(:new).and_return(matcher)

    Dir.mktmpdir do |dir|
      path = File.join(dir, "BREW-requests-CVE-2024-1234.json")
      File.write(path, JSON.generate({
        "id"                => "BREW-requests-CVE-2024-1234",
        "affected"          => [{ "package" => { "ecosystem" => "Homebrew", "name" => "requests" } }],
        "database_specific" => { "source" => "matched" },
      }))

      cmd_for("requests", "--output", dir, "--new-history").run
      expect(JSON.parse(File.read(path)).dig("affected", 0, "ranges", 0, "events", 1))
        .to eq("fixed" => "2.28.1")
    end
  end

  it "walks history and closes an existing open range with --new-history" do
    stub_osv_hit("CVE-2024-1234", fixed: "2.28.1")
    matcher = Homebrew::Vulns::Match.new
    expect(matcher).to receive(:first_fixed_version).and_return("2.28.1")
    allow(Homebrew::Vulns::Match).to receive(:new).and_return(matcher)

    Dir.mktmpdir do |dir|
      path = File.join(dir, "BREW-requests-CVE-2024-1234.json")
      File.write(path, JSON.generate({
        "id"                => "BREW-requests-CVE-2024-1234",
        "affected"          => [{
          "package" => { "ecosystem" => "Homebrew", "name" => "requests" },
          "ranges"  => [{ "type" => "ECOSYSTEM", "events" => [{ "introduced" => "1.0" }] }],
        }],
        "database_specific" => { "source" => "matched" },
      }))

      expect { cmd_for("requests", "--output", dir, "--new-history").run }
        .to output(/1 history walks/).to_stdout
      expect(JSON.parse(File.read(path)).dig("affected", 0, "ranges", 0, "events"))
        .to eq([{ "introduced" => "1.0" }, { "fixed" => "2.28.1" }])
    end
  end

  it "walks history when an existing record is malformed" do
    stub_osv_hit("CVE-2024-1234", fixed: "2.28.1")
    matcher = Homebrew::Vulns::Match.new
    expect(matcher).to receive(:first_fixed_version).and_return("2.28.1")
    allow(Homebrew::Vulns::Match).to receive(:new).and_return(matcher)

    Dir.mktmpdir do |dir|
      path = File.join(dir, "BREW-requests-CVE-2024-1234.json")
      File.write(path, "{")

      cmd_for("requests", "--output", dir, "--new-history").run
      expect(JSON.parse(File.read(path)).dig("affected", 0, "ranges", 0, "events", 1))
        .to eq("fixed" => "2.28.1")
    end
  end

  it "does not walk history for a new record with --no-history" do
    stub_osv_hit("CVE-2024-1234", fixed: "2.28.1")
    matcher = Homebrew::Vulns::Match.new
    expect(matcher).not_to receive(:first_fixed_version)
    allow(Homebrew::Vulns::Match).to receive(:new).and_return(matcher)

    Dir.mktmpdir do |dir|
      cmd_for("requests", "--output", dir, "--no-history").run
    end
  end

  it "does not close an existing open range with --no-history" do
    stub_osv_hit("CVE-2024-1234", fixed: "2.28.1")
    matcher = Homebrew::Vulns::Match.new
    expect(matcher).not_to receive(:first_fixed_version)
    allow(Homebrew::Vulns::Match).to receive(:new).and_return(matcher)

    Dir.mktmpdir do |dir|
      path = File.join(dir, "BREW-requests-CVE-2024-1234.json")
      File.write(path, JSON.generate({
        "id"                => "BREW-requests-CVE-2024-1234",
        "affected"          => [{
          "package" => { "ecosystem" => "Homebrew", "name" => "requests" },
          "ranges"  => [{ "type" => "ECOSYSTEM", "events" => [{ "introduced" => "1.0" }] }],
        }],
        "database_specific" => { "source" => "matched" },
      }))

      cmd_for("requests", "--output", dir, "--no-history").run
      expect(JSON.parse(File.read(path)).dig("affected", 0, "ranges", 0, "events"))
        .to eq([{ "introduced" => "1.0" }])
    end
  end

  it "does not count a history walk for a new record that is still affected" do
    stub_osv_hit("CVE-2024-1234", fixed: "2.32.0")
    matcher = Homebrew::Vulns::Match.new
    expect(matcher).not_to receive(:first_fixed_version)
    allow(Homebrew::Vulns::Match).to receive(:new).and_return(matcher)

    Dir.mktmpdir do |dir|
      expect { cmd_for("requests", "--output", dir, "--new-history").run }
        .to output(/0 history walks/).to_stdout
    end
  end

  it "drops :not_applicable hits instead of emitting them as open ranges" do
    allow(Homebrew::Vulns::OSV).to receive(:query_batch).and_return([[{ "id" => "CVE-2024-1234" }], []])
    allow(Homebrew::Vulns::OSV).to receive(:vulnerability).with("CVE-2024-1234").and_return(
      { "id" => "CVE-2024-1234", "affected" => [{
        "package" => { "ecosystem" => "GIT", "name" => "https://github.com/psf/requests" },
        "ranges"  => [{ "type"   => "ECOSYSTEM",
                        "events" => [{ "introduced" => "3.0.0" }, { "fixed" => "3.0.4" }] }],
      }] },
    )

    expect(JSON.parse(capture_stdout { cmd_for("requests", "--json", "--no-history").run })).to eq []
  end

  it "does not overwrite an existing source: generated record" do
    stub_osv_hit("CVE-2024-1234", fixed: "2.28.1")

    Dir.mktmpdir do |dir|
      path = File.join(dir, "BREW-requests-CVE-2024-1234.json")
      File.write(path, JSON.generate({ "id"                => "BREW-requests-CVE-2024-1234",
                                       "database_specific" => { "source" => "generated" },
                                       "affected"          => [{ "ecosystem_specific" => { "fix" => "patch" } }] }))

      matcher = Homebrew::Vulns::Match.new
      expect(matcher).not_to receive(:first_fixed_version)
      allow(Homebrew::Vulns::Match).to receive(:new).and_return(matcher)

      expect { cmd_for("requests", "--output", dir, "--new-history").run }
        .to output(/0 records written.*1 generated left as-is/).to_stdout
      expect(JSON.parse(File.read(path)).dig("affected", 0, "ecosystem_specific", "fix")).to eq "patch"
    end
  end

  it "emits records as JSON with --json" do
    stub_osv_hit("CVE-2024-1234", fixed: "2.28.1")

    records = JSON.parse(capture_stdout { cmd_for("requests", "--json", "--no-history").run })
    expect(records.length).to eq 1
    expect(records.first["id"]).to eq "BREW-requests-CVE-2024-1234"
  end

  it "prints a per-hit summary in text mode" do
    stub_osv_hit("CVE-2024-1234", fixed: "2.28.1")

    expect { cmd_for("requests", "--no-history").run }
      .to output(/requests 2\.31\.0.*CVE-2024-1234 \[git, high\].*fixed \(upstream 2\.28\.1\).*1 candidate/m)
      .to_stdout
  end

  it "loads the Repology index from --repology=<file> instead of the published feed" do
    stub_osv_hit("CVE-2024-1234", fixed: "2.28.1")

    Dir.mktmpdir do |dir|
      path = File.join(dir, "repology.json")
      File.write(path, JSON.generate({ "meta" => {}, "formulae" => {} }))
      expect(Homebrew::Vulns::Repology).not_to receive(:load)

      records = JSON.parse(capture_stdout do
        cmd_for("requests", "--json", "--no-history", "--repology", path).run
      end)
      expect(records.first["id"]).to eq "BREW-requests-CVE-2024-1234"
    end
  end

  it "raises on an unreadable --repology file" do
    expect { cmd_for("requests", "--json", "--repology", "/nonexistent/repology.json").run }
      .to raise_error(Errno::ENOENT)
  end

  it "reports an OSV outage and finishes the emitter without raising" do
    allow(Homebrew::Vulns::OSV).to receive(:query_batch)
      .and_raise(Homebrew::Vulns::OSV::ApiError, "503")

    expect { cmd_for("requests", "--json").run }
      .to output("[]\n").to_stdout.and output(/OSV query failed: 503/).to_stderr
    expect(Homebrew.failed?).to be true
  end

  it "iterates every core formula with --all and streams to --output" do
    requests
    core_tap = instance_double(CoreTap, installed?: true, name: "homebrew/core",
                               formula_names: ["requests", "broken"])
    allow(CoreTap).to receive(:instance).and_return(core_tap)
    allow(Formulary).to receive(:factory).with("requests").and_return(requests)
    allow(Formulary).to receive(:factory).with("broken").and_raise(RuntimeError, "boom")
    stub_osv_hit("CVE-2024-1234", fixed: "2.28.1")

    Dir.mktmpdir do |dir|
      expect { described_class.new(["--all", "--output", dir, "--no-history"]).run }
        .to output(/1 records written/).to_stdout
        .and output(/Error loading formula 'broken': boom/).to_stderr
      expect(File).to exist(File.join(dir, "BREW-requests-CVE-2024-1234.json"))
    end
  end

  it "rejects --all with --json" do
    expect { described_class.new(["--all", "--json"]) }.to raise_error(UsageError, /mutually exclusive/)
  end

  it "requires --output with --new-history" do
    expect { described_class.new(["requests", "--new-history"]) }
      .to raise_error(UsageError, /--new-history.*--output/)
  end

  it "rejects --new-history with --no-history" do
    expect { described_class.new(["requests", "--output", "out", "--new-history", "--no-history"]) }
      .to raise_error(UsageError, /mutually exclusive/)
  end

  it "emits the formula-identity index with --index" do
    requests
    core_tap = instance_double(CoreTap, installed?: true, name: "homebrew/core", formula_names: ["requests"])
    allow(CoreTap).to receive(:instance).and_return(core_tap)
    allow(Formulary).to receive(:factory).with("requests").and_return(requests)

    output = capture_stdout { described_class.new(["--index"]).run }
    index = JSON.parse(output)
    expect(index.dig("requests", "git_repo")).to eq "https://github.com/psf/requests"
    expect(index.dig("requests", "primary_package", "ecosystem")).to eq "PyPI"
  end

  def capture_stdout
    out = StringIO.new
    old = $stdout
    $stdout = out
    yield
    out.string
  ensure
    $stdout = old
  end
end
