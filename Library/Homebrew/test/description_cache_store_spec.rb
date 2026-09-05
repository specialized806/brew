# typed: true
# frozen_string_literal: true

require "cmd/update-report"
require "description_cache_store"

RSpec.describe DescriptionCacheStore do
  subject(:cache_store) { described_class.new(database) }

  let(:database) { instance_double(CacheStoreDatabase, "database") }
  let(:formula_name) { "test_name" }
  let(:description) { "test_description" }

  def expect_untrusted_cached_description_removed(cache_store, database, type)
    trusted_name = "thirdparty/tap/trusted"
    untrusted_name = "thirdparty/tap/untrusted"
    allow(Homebrew::EnvConfig).to receive(:no_require_tap_trust?).and_return(false)
    allow(database).to receive(:each_key).and_yield("core-item").and_yield(trusted_name).and_yield(untrusted_name)
    allow(database).to receive(:empty?).and_return(false)
    allow(Homebrew::Trust).to receive(:trusted?).with(type, trusted_name).and_return(true)
    allow(Homebrew::Trust).to receive(:trusted?).with(type, untrusted_name).and_return(false)
    expect(database).to receive(:delete).with(untrusted_name)
    expect(database).to receive(:select).and_return({})

    cache_store.select { true }
  end

  it "removes untrusted cached formula descriptions before selecting" do
    expect_untrusted_cached_description_removed(cache_store, database, :formula)
  end

  describe "#update!" do
    it "sets the formula description" do
      expect(database).to receive(:set).with(formula_name, description)
      cache_store.update!(formula_name, description)
    end
  end

  describe "#delete!" do
    it "deletes the formula description" do
      expect(database).to receive(:delete).with(formula_name)
      cache_store.delete!(formula_name)
    end
  end

  describe "#update_from_report!" do
    let(:report) { instance_double(ReporterHub, select_formula_or_cask: [], empty?: false) }

    it "reads from the report" do
      expect(database).to receive(:empty?).at_least(:once).and_return(false)
      cache_store.update_from_report!(report)
    end
  end

  describe "#update_from_formula_names!" do
    it "sets the formulae descriptions" do
      f = formula do
        T.bind(self, T.class_of(Formula))
        url "url-1"
        desc "desc"
      end
      expect(Formulary).to receive(:factory).with(f.name).and_return(f)
      expect(database).to receive(:empty?).and_return(false)
      expect(database).to receive(:set).with(f.name, f.desc)
      cache_store.update_from_formula_names!([f.name])
    end

    it "deletes untrusted formulae descriptions" do
      expect(Formulary).to receive(:factory).with(formula_name).and_raise(Homebrew::UntrustedTapError)
      expect(database).to receive(:empty?).and_return(false)
      expect(database).to receive(:delete).with(formula_name)

      cache_store.update_from_formula_names!([formula_name])
    end
  end

  describe "#delete_from_formula_names!" do
    it "deletes the formulae descriptions" do
      expect(database).to receive(:empty?).and_return(false)
      expect(database).to receive(:delete).with(formula_name)
      cache_store.delete_from_formula_names!([formula_name])
    end
  end

  describe CaskDescriptionCacheStore do
    subject(:cache_store) { described_class.new(database) }

    let(:database) { instance_double(CacheStoreDatabase, "database") }

    it "removes untrusted cached cask descriptions before selecting" do
      expect_untrusted_cached_description_removed(cache_store, database, :cask)
    end

    describe "#update_from_report!" do
      let(:report) { instance_double(ReporterHub, select_formula_or_cask: [], empty?: false) }

      it "reads from the report" do
        expect(database).to receive(:empty?).at_least(:once).and_return(false)
        cache_store.update_from_report!(report)
      end
    end

    describe "#update_from_cask_tokens!" do
      it "sets the cask descriptions" do
        c = Cask::Cask.new("cask-names-desc") do
          url "url-1"
          name "Name 1"
          name "Name 2"
          desc "description"
        end
        expect(Cask::CaskLoader).to receive(:load).with("cask-names-desc", any_args).and_return(c)
        expect(database).to receive(:empty?).and_return(false)
        expect(database).to receive(:set).with(c.full_name, [c.name.join(", "), c.desc.presence])
        cache_store.update_from_cask_tokens!([c.token])
      end

      it "deletes untrusted cask descriptions" do
        token = "thirdparty/tap/untrusted-cask"
        expect(Cask::CaskLoader).to receive(:load).with(token, any_args).and_raise(Homebrew::UntrustedTapError)
        expect(database).to receive(:empty?).and_return(false)
        expect(database).to receive(:delete).with(token)

        cache_store.update_from_cask_tokens!([token])
      end
    end
  end
end
