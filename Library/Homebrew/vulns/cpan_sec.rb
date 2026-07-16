# typed: strict
# frozen_string_literal: true

require "json"
require "tempfile"
require "utils/curl"

module Homebrew
  module Vulns
    # Loader for the CPAN Security Advisory database.
    # Source: https://github.com/briandfoy/cpan-security-advisory
    #
    # The upstream repository ships a compiled `cpan-security-advisory.json`
    # keyed on CPAN distribution name. This class fetches and caches that file
    # and exposes advisories per distribution. Evaluating `affected_versions`
    # range strings against a formula version is left to {Vulns::Match}.
    class CPANSec
      extend Utils::Output::Mixin

      DATA_URL = "https://raw.githubusercontent.com/briandfoy/cpan-security-advisory/" \
                 "master/cpan-security-advisory.json"
      CACHE_FILENAME = "cpansa.json"
      DEFAULT_MAX_AGE = 86_400
      private_constant :CACHE_FILENAME, :DEFAULT_MAX_AGE

      class Error < RuntimeError; end

      Advisory = Struct.new(
        :id, :cves, :affected_versions, :fixed_versions,
        :severity, :description, :references, :reported,
        keyword_init: true
      )

      sig { params(cache: Pathname, max_age: Integer).returns(T.attached_class) }
      def self.load(cache: HOMEBREW_CACHE/"vulns", max_age: DEFAULT_MAX_AGE)
        cache_file = cache/CACHE_FILENAME
        return from_file(cache_file) if cache_file.exist? && (Time.now - cache_file.mtime) <= max_age

        refresh(cache_file)
      rescue ErrorDuringExecution, Error => e
        raise unless cache_file.exist?

        opoo "Failed to refresh CPANSA data (#{e.message.lines.first&.strip}); " \
             "using cached copy from #{cache_file.mtime}."
        from_file(cache_file)
      end

      # Download to a per-process sibling temp file and validate before
      # atomically replacing the cache so a failed, truncated or concurrent
      # fetch cannot corrupt the stale copy.
      sig { params(cache_file: Pathname).returns(T.attached_class) }
      def self.refresh(cache_file)
        cache_file.dirname.mkpath
        Tempfile.create([CACHE_FILENAME, ".download"], cache_file.dirname.to_s) do |tmp|
          tmp.close
          path = Pathname(tmp.path)
          Utils::Curl.curl_download("--fail", "--silent", DATA_URL, to: path)
          loaded = from_file(path)
          File.rename(path, cache_file)
          return loaded
        end
      end

      sig { params(path: Pathname).returns(T.attached_class) }
      def self.from_file(path)
        new(JSON.parse(path.read))
      rescue JSON::ParserError => e
        raise Error, "Failed to parse CPANSA data at #{path}: #{e.message}"
      end

      sig { params(data: T.anything).void }
      def initialize(data)
        raise Error, "CPANSA data is not a JSON object" unless (top = as_hash(data))
        raise Error, "CPANSA data missing 'dists' key" unless (dists = as_hash(top["dists"]))

        @dists = T.let(dists, T::Hash[String, T.untyped])
        @meta = T.let(as_hash(top["meta"]) || {}, T::Hash[String, T.untyped])
      end

      sig { params(value: T.anything).returns(T.nilable(T::Hash[String, T.untyped])) }
      def as_hash(value)
        case value
        when Hash then value
        end
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
