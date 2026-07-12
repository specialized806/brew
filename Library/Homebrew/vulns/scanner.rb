# typed: strict
# frozen_string_literal: true

require "vulns/osv"
require "vulns/vulnerability"

module Homebrew
  module Vulns
    class Scanner
      FORGES = %w[github.com gitlab.com codeberg.org].freeze
      private_constant :FORGES

      TAG_PATTERNS = T.let(
        [
          %r{/archive/refs/tags/([^/]+)\.tar\.gz$},
          %r{/archive/refs/tags/([^/]+)\.zip$},
          %r{/archive/([^/]+)\.tar\.gz$},
          %r{/archive/([^/]+)\.zip$},
          %r{/releases/download/([^/]+)/},
          %r{/tarball/([^/]+)$},
        ].freeze,
        T::Array[Regexp],
      )
      private_constant :TAG_PATTERNS

      sig { params(stable_url: T.nilable(String), head_url: T.nilable(String)).returns(T.nilable(String)) }
      def self.repo_url(stable_url, head_url = nil)
        [stable_url, head_url].each do |url|
          next if url.nil?

          forge = FORGES.find { |f| url.include?(f) }
          next if forge.nil?

          match = url.match(%r{https?://#{Regexp.escape(forge)}/([^/]+/[^/]+)})
          next if match.nil?

          repo_path = T.must(match[1]).sub(/\.git$/, "").sub(%r{/-/.*}, "")
          return "https://#{forge}/#{repo_path}"
        end
        nil
      end

      sig { params(url: T.nilable(String)).returns(T.nilable(String)) }
      def self.tag(url)
        return if url.nil?

        TAG_PATTERNS.each do |pattern|
          match = url.match(pattern)
          return match[1] if match
        end
        nil
      end

      sig { params(serialized_patches: T::Array[T::Hash[String, T.untyped]]).returns(T::Array[String]) }
      def self.resolved_ids(serialized_patches)
        serialized_patches
          .flat_map { |p| Array(p["resolves"]) }
          .select { |r| r.is_a?(Hash) && r["type"] == "security" }
          .map { |r| r["id"].to_s.upcase }
          .uniq
      end
    end
  end
end
