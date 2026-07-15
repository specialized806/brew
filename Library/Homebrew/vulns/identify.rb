# typed: strict
# frozen_string_literal: true

module Homebrew
  module Vulns
    # Derives OSV.dev query keys (forge repo URL, release tag) from formula
    # source URLs. Shared between {Scanner} and the advisory-matching pipeline.
    module Identify
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

      sig { params(urls: T.nilable(String)).returns(T.nilable(String)) }
      def self.repo_url(*urls)
        urls.each do |url|
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
    end
  end
end
