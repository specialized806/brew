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
end
