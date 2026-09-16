# typed: true
# frozen_string_literal: true

require "vulns/history"

RSpec.describe Homebrew::Vulns::History do
  subject(:history) { described_class.new }

  let(:requests) do
    formula("requests") do
      T.bind(self, T.class_of(Formula))
      url "https://files.pythonhosted.org/packages/aa/bb/cc/requests-2.31.0.tar.gz"
    end
  end
  let(:other) do
    formula("other") do
      T.bind(self, T.class_of(Formula))
      url "https://example.test/other-1.0.tar.gz"
    end
  end
  let(:formula_versions) { instance_double(FormulaVersions) }

  before do
    allow(FormulaVersions).to receive(:new).and_return(formula_versions)
  end

  it "returns :history_unavailable for a shallow tap" do
    allow(requests.tap!).to receive(:shallow?).and_return(true)

    expect(history.walk(requests) { :stop }).to eq :history_unavailable
  end

  it "returns :history_unavailable when the formula has no git history" do
    allow(formula_versions).to receive(:rev_list)

    expect(history.walk(requests) { :stop }).to eq :history_unavailable
  end

  it "returns :history_unavailable when a revision cannot be loaded" do
    allow(formula_versions).to receive(:rev_list).and_yield("r0", "Formula/r/requests.rb")
    allow(formula_versions).to receive(:formula_at_revision).and_return(nil)

    expect(history.walk(requests) { nil }).to eq :history_unavailable
  end

  it "stops at the first result the block returns" do
    allow(formula_versions).to receive(:rev_list)
      .and_yield("r0", "Formula/r/requests.rb")
      .and_yield("r1", "Formula/r/requests.rb")
      .and_yield("r2", "Formula/r/requests.rb")
    allow(formula_versions).to receive(:formula_at_revision).and_yield(requests)
    visited = T.let(0, Integer)

    result = history.walk(requests) do |_old|
      visited += 1
      "2.31.0" if visited == 2
    end

    expect([result, visited]).to eq ["2.31.0", 2]
  end

  it "returns nil after visiting every revision" do
    allow(formula_versions).to receive(:rev_list)
      .and_yield("r0", "Formula/r/requests.rb")
      .and_yield("r1", "Formula/r/requests.rb")
    allow(formula_versions).to receive(:formula_at_revision).and_yield(requests)

    expect(history.walk(requests) { nil }).to be_nil
  end

  it "reuses the rev-list for later walks of the same formula" do
    expect(formula_versions).to receive(:rev_list).once.and_yield("r0", "Formula/r/requests.rb")
    allow(formula_versions).to receive(:formula_at_revision).and_yield(requests)

    2.times { history.walk(requests) { nil } }
  end

  it "shares revision enumeration across platform views" do
    expect(formula_versions).to receive(:rev_list).once.and_yield("r0", "Formula/r/requests.rb")
    allow(formula_versions).to receive(:formula_at_revision).and_yield(requests)

    [[:sequoia, :arm], [:sequoia, :intel], [:linux, :arm], [:linux, :intel]].each do |os, arch|
      Homebrew::SimulateSystem.with(os:, arch:) { history.walk(requests) { nil } }
    end
  end

  it "checks a full tap only once across formulae" do
    allow(other).to receive(:tap).and_return(requests.tap!)
    expect(requests.tap!).to receive(:shallow?).once.and_return(false)
    allow(formula_versions).to receive(:rev_list).and_yield("r0", "Formula/r/requests.rb")
    allow(formula_versions).to receive(:formula_at_revision).and_yield(requests)

    [requests, other].each { |formula| history.walk(formula) { nil } }
  end

  it "keeps a cached shallow tap unavailable" do
    expect(requests.tap!).to receive(:shallow?).once.and_return(true)
    results = Array.new(2) { history.walk(requests) { :stop } }

    expect(results).to eq [:history_unavailable, :history_unavailable]
  end

  it "does not share shallow status between taps" do
    allow(requests.tap!).to receive(:shallow?).and_return(false)
    allow(other).to receive(:tap).and_return(instance_double(Tap, path: Pathname("/other-tap"), shallow?: true))
    allow(formula_versions).to receive(:rev_list).and_yield("r0", "Formula/r/requests.rb")
    allow(formula_versions).to receive(:formula_at_revision).and_yield(requests)
    history.walk(requests) { nil }

    expect(history.walk(other) { :stop }).to eq :history_unavailable
  end

  it "rechecks shallow status in a new history instance" do
    allow(requests.tap!).to receive(:shallow?).and_return(false, true)
    allow(formula_versions).to receive(:rev_list).and_yield("r0", "Formula/r/requests.rb")
    allow(formula_versions).to receive(:formula_at_revision).and_yield(requests)
    history.walk(requests) { nil }

    expect(described_class.new.walk(requests) { :stop }).to eq :history_unavailable
  end

  it "keeps revision lists separate for formulae in the same tap" do
    other_versions = instance_double(FormulaVersions)
    allow(FormulaVersions).to receive(:new).with(other).and_return(other_versions)
    allow(formula_versions).to receive(:rev_list).and_yield("r0", "Formula/r/requests.rb")
    allow(formula_versions).to receive(:formula_at_revision).and_yield(requests)
    expect(other_versions).to receive(:rev_list).once.and_yield("r1", "Formula/o/other.rb")
    allow(other_versions).to receive(:formula_at_revision).and_yield(other)

    [requests, other].each { |formula| history.walk(formula) { nil } }
  end

  it "does not reuse historical formula loads across platforms" do
    allow(formula_versions).to receive(:rev_list).and_yield("r0", "Formula/r/requests.rb")
    allow(formula_versions).to receive(:formula_at_revision).and_yield(requests)
    expect(FormulaVersions).to receive(:new).with(requests).twice.and_return(formula_versions)

    Homebrew::SimulateSystem.with(os: :linux, arch: :arm) { history.walk(requests) { nil } }
    Homebrew::SimulateSystem.with(os: :linux, arch: :intel) { history.walk(requests) { nil } }
  end
end
