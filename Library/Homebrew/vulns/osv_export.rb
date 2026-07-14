# typed: strict
# frozen_string_literal: true

require "json"
require "fileutils"
require "vulns/osv"
require "vulns/scanner"

module Homebrew
  module Vulns
    # Emits OSV-schema records for the `Homebrew` ecosystem describing CVEs that
    # homebrew-core formulae resolve via shipped patches.
    #
    # One record is written per (formula, vulnerability id) pair found in
    # `serialized_patches[].resolves`. The record states that the formula was
    # affected up to (but not including) the currently shipped version+revision;
    # this is a "fixed at or before what we ship today" approximation, since the
    # precise fix boundary requires homebrew-core git archaeology.
    #
    # Record shape follows the OSV 1.7 schema and mirrors the Debian DSA layout
    # (`upstream` listing the source CVE, `affected[].ranges` of type
    # `ECOSYSTEM`, `ecosystem_specific` carrying the resolving patch detail).
    #
    # See {Homebrew::DevCmd::GenerateVulnsAdvisories} for the entry point and
    # https://github.com/Homebrew/homebrew-advisory-database for the published
    # feed.
    module OsvExport
      SCHEMA_VERSION = "1.7.3"
      ECOSYSTEM = "Homebrew"
      ID_PREFIX = "BREW"

      # `annotated` is a list of `[formula, serialized_patches]` pairs. The
      # patches are passed in rather than read from the formula so callers can
      # supply the union across OS/architecture variations (a `patch` inside an
      # `on_linux`/`on_intel` block only appears in `Formula#serialized_patches`
      # under the matching {SimulateSystem}).
      sig {
        params(annotated: T::Array[[Formula, T::Array[T::Hash[String, T.untyped]]]],
               dir:       T.any(String, Pathname), now: Time)
          .returns(T::Array[String])
      }
      def self.run(annotated, dir, now: Time.now.utc)
        FileUtils.mkdir_p(dir)
        written = []
        upstream_cache = T.let({}, T::Hash[String, T.nilable(T::Hash[String, T.untyped])])

        annotated.each do |formula, patches|
          Scanner.resolved_ids(patches).each do |vuln_id|
            upstream = upstream_cache.fetch(vuln_id) { upstream_cache[vuln_id] = fetch_upstream(vuln_id) }
            record = record_for(formula, vuln_id, patches:, upstream:, now:)
            path = File.join(dir, "#{record.fetch(:id)}.json")
            File.write(path, "#{JSON.pretty_generate(record)}\n")
            written << path
          end
        end

        written
      end

      sig {
        params(formula: Formula, vuln_id: String, patches: T::Array[T::Hash[String, T.untyped]],
               upstream: T.nilable(T::Hash[String, T.untyped]), now: Time)
          .returns(T::Hash[Symbol, T.untyped])
      }
      def self.record_for(formula, vuln_id, patches: formula.serialized_patches, upstream: nil, now: Time.now.utc)
        record = T.let({
          schema_version: SCHEMA_VERSION,
          id:             "#{ID_PREFIX}-#{formula.name}-#{vuln_id}",
          modified:       now.strftime("%Y-%m-%dT%H:%M:%SZ"),
          upstream:       [vuln_id],
          affected:       [affected_entry(formula, vuln_id, patches)],
        }, T::Hash[Symbol, T.untyped])

        if upstream
          record[:summary] = upstream["summary"] if upstream["summary"]
          record[:details] = upstream["details"] if upstream["details"]
          record[:severity] = upstream["severity"] if upstream["severity"]
          record[:upstream] = ([vuln_id] + Array(upstream["aliases"])).uniq
          record[:references] = upstream["references"] if upstream["references"]
        end

        record
      end

      sig {
        params(formula: Formula, vuln_id: String, patches: T::Array[T::Hash[String, T.untyped]])
          .returns(T::Hash[Symbol, T.untyped])
      }
      def self.affected_entry(formula, vuln_id, patches)
        {
          package:            {
            ecosystem: ECOSYSTEM,
            name:      formula.name,
            purl:      purl(formula.name),
          },
          ranges:             [
            {
              type:   "ECOSYSTEM",
              events: [{ introduced: "0" }, { fixed: formula.pkg_version.to_s }],
            },
          ],
          ecosystem_specific: {
            fix:     "patch",
            patches: patches_resolving(patches, vuln_id).filter_map { |p| patch_ref(p) },
          },
        }
      end

      # Formula names use `[a-z0-9._+@-]`. Of those, `@` and `+` fall outside the
      # purl-spec unreserved set for the name component and must be
      # percent-encoded (`@` would otherwise be read as the name/version
      # separator; `+` is disallowed unencoded in a canonical purl name).
      PURL_NAME_ENCODE = T.let({ "@" => "%40", "+" => "%2B" }.freeze, T::Hash[String, String])
      private_constant :PURL_NAME_ENCODE

      sig { params(name: String).returns(String) }
      def self.purl(name)
        "pkg:brew/#{name.gsub(/[@+]/, PURL_NAME_ENCODE)}"
      end

      sig {
        params(serialized_patches: T::Array[T::Hash[String, T.untyped]], vuln_id: String)
          .returns(T::Array[T::Hash[String, T.untyped]])
      }
      def self.patches_resolving(serialized_patches, vuln_id)
        target = vuln_id.upcase
        serialized_patches.select do |p|
          Array(p["resolves"]).any? { |r| r.is_a?(Hash) && r["type"] == "security" && r["id"].to_s.upcase == target }
        end
      end

      sig { params(patch: T::Hash[String, T.untyped]).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
      def self.patch_ref(patch)
        ref = {}
        ref[:type] = patch["type"] if patch["type"]
        ref[:url] = patch["url"] if patch["url"]
        ref[:file] = patch["file"] if patch["file"]
        ref[:apply] = patch["apply"] if patch["apply"]
        ref.presence
      end

      sig { params(vuln_id: String).returns(T.nilable(T::Hash[String, T.untyped])) }
      def self.fetch_upstream(vuln_id)
        OSV.vulnerability(vuln_id)
      rescue OSV::Error
        nil
      end
    end
  end
end
