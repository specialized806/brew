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

      Finding = Struct.new(:name, :version, :tag, :repo_url, :open, :patched, keyword_init: true)

      class Results
        sig { returns(T::Array[Finding]) }
        attr_reader :findings

        sig { returns(Integer) }
        attr_reader :checked, :skipped

        sig { params(findings: T::Array[Finding], checked: Integer, skipped: Integer).void }
        def initialize(findings:, checked:, skipped:)
          @findings = findings
          @checked = checked
          @skipped = skipped
        end

        sig { returns(T::Boolean) }
        def any_open?
          findings.any? { |f| f.open.any? }
        end
      end

      MAX_VULN_FETCH_THREADS = 15
      private_constant :MAX_VULN_FETCH_THREADS

      SEVERITY_LEVELS = T.let(
        { low: 1, medium: 2, high: 3, critical: 4 }.freeze,
        T::Hash[Symbol, Integer],
      )
      private_constant :SEVERITY_LEVELS

      sig {
        params(formulae: T::Array[Formula], ignore_patches: T::Boolean, min_severity: T.nilable(Symbol)).void
      }
      def initialize(formulae, ignore_patches: true, min_severity: nil)
        @formulae = formulae
        @ignore_patches = ignore_patches
        @min_severity_level = T.let(min_severity ? SEVERITY_LEVELS.fetch(min_severity) : 0, Integer)
      end

      sig { returns(Results) }
      def scan
        queryable, skipped = @formulae.partition { |f| target_for(f) }
        return Results.new(findings: [], checked: 0, skipped: skipped.size) if queryable.empty?

        targets = queryable.map { |f| T.must(target_for(f)) }
        batch = OSV.query_batch(targets.map { |t| { repo_url: t.fetch(:repo_url), version: t.fetch(:tag) } })

        findings = queryable.each_with_index.filter_map do |formula, index|
          target = targets.fetch(index)
          ids = batch.fetch(index)
          next if ids.empty?

          vulns = fetch_vulnerabilities(ids)
                  .select { |v| v.affects_version?(target.fetch(:tag)) }
                  .select { |v| v.severity_level >= @min_severity_level }
          next if vulns.empty?

          open, patched = partition_patched(formula, vulns)
          next if open.empty? && patched.empty?

          Finding.new(
            name:     formula.name,
            version:  formula.version.to_s,
            tag:      target.fetch(:tag),
            repo_url: target.fetch(:repo_url),
            open:,
            patched:,
          )
        end

        Results.new(findings:, checked: queryable.size, skipped: skipped.size)
      end

      sig { params(formula: Formula).returns(T.nilable({ repo_url: String, tag: String })) }
      def target_for(formula)
        @targets ||= T.let({}, T.nilable(T::Hash[String, T.nilable({ repo_url: String, tag: String })]))
        @targets.fetch(formula.full_name) do
          stable_url = formula.stable&.url
          repo_url = self.class.repo_url(stable_url, formula.head&.url)
          tag = self.class.tag(stable_url)
          @targets[formula.full_name] = (repo_url && tag) ? { repo_url:, tag: } : nil
        end
      end

      sig { params(ids: T::Array[T::Hash[String, T.untyped]]).returns(T::Array[Vulnerability]) }
      def fetch_vulnerabilities(ids)
        records = ids.each_slice(MAX_VULN_FETCH_THREADS).flat_map do |slice|
          slice
            .map { |v| Thread.new { OSV.vulnerability(v.fetch("id")) } }
            .map { |t| T.cast(t.value, T::Hash[String, T.untyped]) }
        end
        Vulnerability.from_osv_list(records)
      end

      sig {
        params(formula: Formula, vulns: T::Array[Vulnerability])
          .returns([T::Array[Vulnerability], T::Array[Vulnerability]])
      }
      def partition_patched(formula, vulns)
        return [vulns, []] unless @ignore_patches

        resolved = self.class.resolved_ids(formula.serialized_patches)
        return [vulns, []] if resolved.empty?

        patched, open = vulns.partition do |v|
          v.identifiers.any? { |id| resolved.include?(id.to_s.upcase) }
        end
        [open, patched]
      end
    end
  end
end
