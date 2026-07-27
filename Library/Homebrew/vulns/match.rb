# typed: strict
# frozen_string_literal: true

require "formula_versions"
require "vulns/cpan_sec"
require "vulns/identify"
require "vulns/osv"
require "vulns/osv_export"
require "vulns/repology"
require "vulns/vulnerability"

module Homebrew
  module Vulns
    # Authoring-time advisory matcher. For a given {Formula} it derives every
    # OSV.dev query key it can (forge repository, language-registry package for
    # the primary URL and each `resource`, distro source packages via
    # {Repology}, CPAN distribution via {CPANSec}) and returns the deduplicated
    # set of vulnerabilities any of them hit, tagged with the strategy that
    # reached each one.
    #
    # Runs in `Homebrew/advisory-database` CI and the homebrew-core PR bot to
    # produce candidate `BREW-*` records for human review; never on a user's
    # machine, so request volume and false-positive rate are traded for recall.
    class Match
      include Utils::Output::Mixin

      # Descending precision. When several strategies reach the same CVE the
      # highest is reported as the hit's primary strategy; the rest are kept as
      # supporting evidence.
      STRATEGY_PRECISION = T.let(
        { git: 4, registry: 3, cpansa: 2, distro: 1 }.freeze,
        T::Hash[Symbol, Integer],
      )

      # Recorded in `database_specific.confidence` for the reviewer.
      CONFIDENCE = T.let(
        { git: "high", registry: "high", cpansa: "medium", distro: "low" }.freeze,
        T::Hash[Symbol, String],
      )

      Identity = Struct.new(
        :git_repo, :git_tag, :primary_package, :resource_packages, :distro_packages,
        keyword_init: true
      ) do
        sig { returns(T::Boolean) }
        def identifiable?
          !git_repo.nil? || !primary_package.nil? || resource_packages.any? || distro_packages.any?
        end
      end

      Evidence = Struct.new(:strategy, :key, :resource, keyword_init: true)

      class Hit
        sig { returns(Vulnerability) }
        attr_reader :vulnerability

        sig { returns(T::Array[Evidence]) }
        attr_reader :evidence

        sig { params(vulnerability: Vulnerability, evidence: T::Array[Evidence]).void }
        def initialize(vulnerability:, evidence:)
          raise ArgumentError, "Hit requires at least one Evidence" if evidence.empty?

          @vulnerability = vulnerability
          @evidence = T.let(
            evidence.sort_by { |e| -STRATEGY_PRECISION.fetch(e.strategy) }.freeze,
            T::Array[Evidence],
          )
        end

        sig { returns(Symbol) }
        def strategy
          evidence.fetch(0).strategy
        end

        sig { returns(T.nilable(String)) }
        def resource
          evidence.fetch(0).resource
        end

        sig { returns(String) }
        def canonical_id
          vulnerability.cve_ids.min || vulnerability.id
        end
      end

      sig { params(repology: T.nilable(Repology), cpan_sec: T.nilable(CPANSec)).void }
      def initialize(repology: nil, cpan_sec: nil)
        @repology = repology
        @cpan_sec = cpan_sec
        @vuln_cache = T.let({}, T::Hash[String, T.nilable(T::Hash[String, T.untyped])])
        @formula_versions = T.let({}, T::Hash[String, FormulaVersions])
        @formula_rev_lists = T.let({}, T::Hash[String, T::Array[[String, String]]])
      end

      sig { returns(Repology) }
      def repology
        @repology ||= Repology.load
      end

      sig { returns(CPANSec) }
      def cpan_sec
        @cpan_sec ||= CPANSec.load
      end

      sig { params(formula: Formula).returns(Identity) }
      def identify(formula)
        stable = formula.stable
        stable_url = stable&.url
        Identity.new(
          git_repo:          Identify.repo_url(stable_url, formula.head&.url, formula.homepage),
          git_tag:           Identify.tag(stable_url) || stable&.specs&.dig(:tag) || stable&.version&.to_s,
          primary_package:   Identify.registry_package(stable_url),
          resource_packages: formula.resources.filter_map do |r|
            pkg = Identify.registry_package(r.url)
            [r.name, pkg] if pkg
          end.to_h.freeze,
          distro_packages:   distro_packages_for(formula.name),
        ).freeze
      end

      # Returns one {Hit} per distinct vulnerability (grouped by CVE alias)
      # reached by any strategy. Each hit's `evidence` lists every path that
      # reached it, highest-precision first.
      sig { params(formula: Formula).returns(T::Array[Hit]) }
      def advisories_for(formula)
        identity = identify(formula)
        return [] unless identity.identifiable?

        labelled = build_osv_queries(identity)
        id_evidence = T.let({}, T::Hash[String, T::Array[Evidence]])

        if labelled.any?
          OSV.query_batch(labelled.map(&:first)).each_with_index do |stubs, i|
            evidence = labelled.fetch(i).last
            stubs.each { |stub| (id_evidence[stub.fetch("id")] ||= []) << evidence }
          end
        end

        cpan_advisory_ids(identity).each { |id, evidence| (id_evidence[id] ||= []) << evidence }

        hits = id_evidence.filter_map do |id, evidence|
          record = fetch_vulnerability(id)
          Hit.new(vulnerability: Vulnerability.new(record), evidence:) if record
        end

        dedup_by_cve(hits)
      end

      sig { params(identity: Identity).returns(T::Array[[OSV::Package, Evidence]]) }
      def build_osv_queries(identity)
        queries = T.let([], T::Array[[OSV::Package, Evidence]])

        if (repo = identity.git_repo) && (tag = identity.git_tag)
          queries << [{ ecosystem: "GIT", name: repo, version: tag },
                      Evidence.new(strategy: :git, key: repo).freeze]
        end

        if (pkg = identity.primary_package) && pkg.ecosystem != "CPAN"
          queries << [{ ecosystem: pkg.ecosystem, name: pkg.name, version: pkg.version },
                      Evidence.new(strategy: :registry, key: pkg.purl).freeze]
        end

        identity.resource_packages.each do |resource, pkg|
          next if pkg.ecosystem == "CPAN"

          queries << [{ ecosystem: pkg.ecosystem, name: pkg.name, version: pkg.version },
                      Evidence.new(strategy: :registry, key: pkg.purl, resource:).freeze]
        end

        identity.distro_packages.each do |ecosystem, srcnames|
          srcnames.each do |srcname|
            queries << [{ ecosystem:, name: srcname, version: nil },
                        Evidence.new(strategy: :distro, key: "#{ecosystem}/#{srcname}").freeze]
          end
        end

        queries
      end

      sig { params(identity: Identity).returns(T::Array[[String, Evidence]]) }
      def cpan_advisory_ids(identity)
        result = T.let([], T::Array[[String, Evidence]])
        cpan_packages(identity).each do |pkg, resource|
          evidence = Evidence.new(strategy: :cpansa, key: pkg.purl, resource:).freeze
          cpan_sec.advisories_for(pkg.name).each do |adv|
            ids = adv.cves.presence || [adv.id.to_s]
            ids.each { |id| result << [id, evidence] }
          end
        end
        result
      end

      sig {
        params(identity: Identity).returns(T::Array[[Identify::RegistryPackage, T.nilable(String)]])
      }
      def cpan_packages(identity)
        result = T.let([], T::Array[[Identify::RegistryPackage, T.nilable(String)]])
        primary = identity.primary_package
        result << [primary, nil] if primary&.ecosystem == "CPAN"
        identity.resource_packages.each do |resource, pkg|
          result << [pkg, resource] if pkg.ecosystem == "CPAN"
        end
        result
      end

      sig { params(name: String).returns(Repology::DistroMap) }
      def distro_packages_for(name)
        indexed = repology.distro_packages_for(name)
        return indexed if indexed.any?

        Repology.lookup(name)
      rescue CachedFeed::Error => e
        odebug "Repology lookup for #{name} failed: #{e.message}"
        {}
      end

      # OSV `querybatch` returns id/modified stubs; the full record is fetched
      # once per id and cached across formulae.
      sig { params(id: String).returns(T.nilable(T::Hash[String, T.untyped])) }
      def fetch_vulnerability(id)
        @vuln_cache.fetch(id) do
          @vuln_cache[id] = begin
            OSV.vulnerability(id)
          rescue OSV::Error => e
            odebug "OSV.vulnerability(#{id}) failed: #{e.message}"
            nil
          end
        end
      end

      # Emit a candidate `BREW-*` OSV record for `hit` against `formula`.
      #
      # `first_fixed` is the {PkgVersion} at which Homebrew first shipped a fix
      # (from {#first_fixed_version} or a hand-set value); when absent, the
      # record marks the current `pkg_version` as fixed if
      # {#upstream_fix_shipped?} says so, otherwise it carries no `fixed` event
      # and `ecosystem_specific.fix` is null. As with {OsvExport.record_for},
      # {OsvExport.merge_existing} preserves the on-disk `ranges` on rewrite so
      # a hand-corrected boundary sticks.
      sig {
        params(formula: Formula, hit: Hit, first_fixed: T.nilable(String), now: Time)
          .returns(T::Hash[Symbol, T.untyped])
      }
      def to_brew_record(formula, hit, first_fixed: nil, now: Time.now.utc)
        vuln = hit.vulnerability
        raw = fetch_vulnerability(vuln.id) || {}
        timestamp = now.strftime("%Y-%m-%dT%H:%M:%SZ")

        fixed = first_fixed
        fixed ||= formula.pkg_version.to_s if upstream_fix_shipped?(subject_version(formula, hit), hit)
        events = T.let([{ introduced: "0" }], T::Array[T::Hash[Symbol, String]])
        events << { fixed: } if fixed

        record = T.let({
          schema_version:    OsvExport::SCHEMA_VERSION,
          id:                "#{OsvExport::ID_PREFIX}-#{formula.name}-#{hit.canonical_id}",
          published:         timestamp,
          modified:          timestamp,
          upstream:          vuln.identifiers.uniq,
          affected:          [affected_entry(formula, hit, events, fixed)],
          database_specific: {
            source:            "matched",
            strategy:          hit.strategy.to_s,
            confidence:        CONFIDENCE.fetch(hit.strategy),
            upstream_evidence: hit.evidence.map { |e| e.to_h.compact },
          },
        }, T::Hash[Symbol, T.untyped])

        record[:summary] = vuln.summary if vuln.summary
        record[:details] = vuln.details if vuln.details
        record[:severity] = raw["severity"] if raw["severity"]
        if (refs = raw["references"])
          record[:references] = refs.uniq { |r| [r["type"], URI::RFC2396_PARSER.unescape(r["url"].to_s)] }
        end

        record
      end

      sig {
        params(formula: Formula, hit: Hit, events: T::Array[T::Hash[Symbol, String]],
               fixed: T.nilable(String)).returns(T::Hash[Symbol, T.untyped])
      }
      def affected_entry(formula, hit, events, fixed)
        eco = T.let({ fix: fixed ? "bump" : nil }, T::Hash[Symbol, T.nilable(String)])
        if (resource = hit.resource)
          eco[:resource] = resource
          eco[:resource_purl] = hit.evidence.find { |e| e.resource == resource }&.key
        end
        {
          package:            {
            ecosystem: OsvExport::ECOSYSTEM,
            name:      formula.name,
            purl:      OsvExport.purl(formula.name),
          },
          ranges:             [{ type: "ECOSYSTEM", events: }],
          ecosystem_specific: eco,
        }
      end

      # For a resource hit, the fix-shipped test compares the resource's pinned
      # version (not the formula's) against the upstream threshold; the emitted
      # `fixed:` boundary is still the formula's `pkg_version` since that is
      # what {ecosystem: Homebrew} range checks match on.
      sig { params(formula: Formula, hit: Hit).returns(T.nilable(Version)) }
      def subject_version(formula, hit)
        if (r = hit.resource)
          begin
            formula.resource(r)&.version
          rescue ResourceMissingError
            nil
          end
        else
          formula.version
        end
      end

      # True when `version` is at or past any upstream fixed version.
      # Distro-strategy fixed versions are distro-specific strings
      # (`1:8.5.0-2`, `+dfsg-1`) and are not compared. Uses {Version}, not
      # {Semver}, since formula versions are not required to be strict semver.
      sig { params(version: T.nilable(Version), hit: Hit).returns(T::Boolean) }
      def upstream_fix_shipped?(version, hit)
        return false if version.nil?

        threshold = comparable_fix_threshold(hit)
        return false if threshold.nil?

        version >= threshold
      end

      sig { params(hit: Hit).returns(T.nilable(Version)) }
      def comparable_fix_threshold(hit)
        return if hit.strategy == :distro

        hit.vulnerability.fixed_versions
           .filter_map { |v| Version.new(v.sub(/\Av/i, "")) if v.present? }
           .min
      end

      # Walk homebrew-core git history (newest first) via {FormulaVersions} and
      # return the `pkg_version` at the oldest revision where the formula
      # version was still at or past the upstream fix threshold. Returns nil
      # when there is no comparable threshold or the current version is not yet
      # fixed. The rev-list and per-revision loads are cached per formula so
      # subsequent hits for the same formula reuse both.
      sig { params(formula: Formula, hit: Hit).returns(T.nilable(String)) }
      def first_fixed_version(formula, hit)
        threshold = comparable_fix_threshold(hit)
        return if threshold.nil?
        return unless upstream_fix_shipped?(subject_version(formula, hit), hit)

        fv = @formula_versions[formula.name] ||= FormulaVersions.new(formula)
        revs = @formula_rev_lists[formula.name] ||=
          [].tap { |a| fv.rev_list("HEAD") { |rev, entry| a << [rev, entry] } }

        last_fixed = T.let(formula.pkg_version.to_s, T.nilable(String))
        revs.each do |rev, entry|
          old_fixed = fv.formula_at_revision(rev, entry) do |old|
            old.pkg_version.to_s if upstream_fix_shipped?(subject_version(old, hit), hit)
          end
          # `nil` from formula_at_revision means the revision failed to load;
          # a `nil` block result means the version dropped below the threshold.
          return last_fixed if old_fixed.nil?

          last_fixed = old_fixed
        end
        last_fixed
      end

      sig { params(hits: T::Array[Hit]).returns(T::Array[Hit]) }
      def dedup_by_cve(hits)
        hits.group_by(&:canonical_id).map do |_, group|
          next group.fetch(0) if group.one?

          primary = T.must(group.max_by { |h| STRATEGY_PRECISION.fetch(h.strategy) })
          Hit.new(vulnerability: primary.vulnerability,
                  evidence:      group.flat_map(&:evidence).uniq)
        end
      end
    end
  end
end
