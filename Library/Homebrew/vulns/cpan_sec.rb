# typed: strict
# frozen_string_literal: true

require "vulns/cached_feed"

module Homebrew
  module Vulns
    # Loader for the CPAN Security Advisory database.
    # Source: https://github.com/briandfoy/cpan-security-advisory
    #
    # The upstream repository ships a compiled `cpan-security-advisory.json`
    # keyed on CPAN distribution name. This class fetches and caches that file
    # and exposes advisories per distribution. Evaluating `affected_versions`
    # range strings against a formula version is left to {Vulns::Match}.
    class CPANSec < CachedFeed
      DATA_URL = "https://raw.githubusercontent.com/briandfoy/cpan-security-advisory/" \
                 "master/cpan-security-advisory.json"

      sig { override.returns(String) }
      def self.data_url = DATA_URL

      sig { override.returns(String) }
      def self.cache_filename = "cpansa.json"

      Advisory = Struct.new(
        :id, :cves, :affected_versions, :fixed_versions,
        :severity, :description, :references, :reported,
        keyword_init: true
      )

      sig { override.params(data: T.anything).void }
      def initialize(data)
        super
        raise Error, "CPANSA data is not a JSON object" unless (top = as_hash(data))
        raise Error, "CPANSA data missing 'dists' key" unless (dists = as_hash(top["dists"]))

        @dists = T.let(dists, T::Hash[String, T.untyped])
        @meta = T.let(as_hash(top["meta"]) || {}, T::Hash[String, T.untyped])
      end

      sig { returns(T::Hash[String, T.untyped]) }
      attr_reader :meta

      sig { returns(T::Array[String]) }
      def distributions
        @dists.keys
      end

      sig { params(distribution: String).returns(T::Array[Advisory]) }
      def advisories_for(distribution)
        entry = @dists[distribution]
        return [] unless entry.is_a?(Hash)

        Array(entry["advisories"]).filter_map { |a| build_advisory(a) if a.is_a?(Hash) }
      end

      sig { params(raw: T::Hash[String, T.untyped]).returns(T.nilable(Advisory)) }
      def build_advisory(raw)
        id = raw["id"]
        return if id.nil?

        Advisory.new(
          id:,
          cves:              Array(raw["cves"]).map(&:to_s),
          affected_versions: Array(raw["affected_versions"]).map(&:to_s),
          fixed_versions:    Array(raw["fixed_versions"]).map(&:to_s),
          severity:          raw["severity"],
          description:       raw["description"],
          references:        Array(raw["references"]).map(&:to_s),
          reported:          raw["reported"],
        ).freeze
      end
    end
  end
end
