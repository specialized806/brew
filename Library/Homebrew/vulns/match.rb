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
    # {Repology}, CPAN distribution via {CPANSec}), issues *versionless* queries
    # against each, resolves distro advisories to their upstream CVEs, and
    # evaluates each hit's affected range against the version we ship.
    #
    # Runs in `Homebrew/advisory-database` CI and the homebrew-core PR bot to
    # produce candidate `BREW-*` records for human review; never on a user's
    # machine, so request volume is traded for recall and every candidate
    # carries a strategy/confidence label for the reviewer.
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

      # `ecosystem`/`name` are the OSV `package` fields queried, so a hit's
      # `affected[]` entry can be matched back to this evidence.
      # `subject_version` is the version to evaluate that entry's ranges
      # against: the formula version for the primary source, the pinned
      # resource version for a resource, `nil` for distro (whose versions are
      # not comparable to ours). `advisory` carries the CPANSA record for
      # `:cpansa` evidence so its constraint strings survive to
      # {#range_status}.
      Evidence = Struct.new(:strategy, :ecosystem, :name, :subject_version, :key, :resource,
                            :advisory, keyword_init: true)

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

        sig { returns(Evidence) }
        def primary_evidence
          evidence.fetch(0)
        end

        sig { returns(Symbol) }
        def strategy
          primary_evidence.strategy
        end

        sig { returns(T.nilable(String)) }
        def resource
          primary_evidence.resource
        end

        sig { returns(String) }
        def canonical_id
          vulnerability.cve_ids.min || vulnerability.id
        end
      end

      sig { params(repology: T.nilable(Repology), cpan_sec: T.nilable(CPANSec), bulk: T::Boolean).void }
      def initialize(repology: nil, cpan_sec: nil, bulk: false)
        @repology = repology
        @cpan_sec = cpan_sec
        @bulk = bulk
        @vuln_cache = T.let({}, T::Hash[String, T.nilable(Vulnerability)])
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
      # reached by any strategy. Distro-ecosystem records are resolved to their
      # `upstream` CVE(s) so multi-CVE advisories split into per-CVE hits and
      # collapse onto the same CVE reached via GIT/registry. All queries are
      # versionless so historic bump-fixed advisories are returned;
      # {#range_status} evaluates each hit against the shipped version.
      sig { params(formula: Formula).returns(T::Array[Hit]) }
      def advisories_for(formula)
        identity = identify(formula)
        return [] unless identity.identifiable?

        labelled = build_osv_queries(identity, formula.version.to_s)
        id_evidence = T.let({}, T::Hash[String, T::Array[Evidence]])

        if labelled.any?
          OSV.query_batch(labelled.map(&:first)).each_with_index do |stubs, i|
            evidence = labelled.fetch(i).last
            stubs.each { |stub| (id_evidence[stub.fetch("id")] ||= []) << evidence }
          end
        end

        cpan_evidence(identity).each do |ev|
          cpan_sec.advisories_for(ev.name).each do |adv|
            annotated = Evidence.new(**ev.to_h, advisory: adv).freeze
            (adv.cves.presence || [adv.id.to_s]).each { |id| (id_evidence[id] ||= []) << annotated }
          end
        end

        hits = resolve_upstream(id_evidence, identity)
        dedup_by_cve(hits)
      end

      sig {
        params(identity: Identity, formula_version: String).returns(T::Array[[OSV::Package, Evidence]])
      }
      def build_osv_queries(identity, formula_version)
        queries = T.let([], T::Array[[OSV::Package, Evidence]])

        if (repo = identity.git_repo)
          queries << [{ ecosystem: "GIT", name: repo, version: nil },
                      Evidence.new(strategy: :git, ecosystem: "GIT", name: repo,
                                   subject_version: identity.git_tag || formula_version,
                                   key: repo).freeze]
        end

        if (pkg = identity.primary_package) && pkg.ecosystem != "CPAN"
          queries << [{ ecosystem: pkg.ecosystem, name: pkg.name, version: nil },
                      Evidence.new(strategy: :registry, ecosystem: pkg.ecosystem, name: pkg.name,
                                   subject_version: pkg.version, key: pkg.purl).freeze]
        end

        identity.resource_packages.each do |resource, pkg|
          next if pkg.ecosystem == "CPAN"

          queries << [{ ecosystem: pkg.ecosystem, name: pkg.name, version: nil },
                      Evidence.new(strategy: :registry, ecosystem: pkg.ecosystem, name: pkg.name,
                                   subject_version: pkg.version, key: pkg.purl, resource:).freeze]
        end

        identity.distro_packages.each do |ecosystem, srcnames|
          srcnames.each do |srcname|
            queries << [{ ecosystem:, name: srcname, version: nil },
                        Evidence.new(strategy: :distro, ecosystem:, name: srcname,
                                     key: "#{ecosystem}/#{srcname}").freeze]
          end
        end

        queries
      end

      sig { params(identity: Identity).returns(T::Array[Evidence]) }
      def cpan_evidence(identity)
        result = T.let([], T::Array[Evidence])
        primary = identity.primary_package
        if primary&.ecosystem == "CPAN"
          result << Evidence.new(strategy: :cpansa, ecosystem: "CPAN", name: primary.name,
                                 subject_version: primary.version, key: primary.purl)
        end
        identity.resource_packages.each do |resource, pkg|
          next if pkg.ecosystem != "CPAN"

          result << Evidence.new(strategy: :cpansa, ecosystem: "CPAN", name: pkg.name,
                                 subject_version: pkg.version, key: pkg.purl, resource:)
        end
        result
      end

      CVE_ID = /\ACVE-\d{4}-\d+\z/
      private_constant :CVE_ID

      # Turn `id => [Evidence, ...]` into `[Hit, ...]`, resolving each record to
      # the canonical CVE(s) it references. Distro advisories name their CVEs in
      # `upstream` (Debian/Ubuntu/RH/openSUSE/...) or `related` (AlmaLinux),
      # often mixed with distro-prefixed ids (`DEBIAN-CVE-*`) that would need
      # another hop; only bare `CVE-YYYY-N` ids are followed. A record that is
      # already a CVE (by id or alias) is kept as-is; one that names no CVE at
      # all is kept as a low-confidence hit rather than dropped. Each resolved
      # hit gains synthesised evidence pointing at our own identity so
      # {#range_status} can check the CVE record's `affected[]` against our
      # version.
      sig {
        params(id_evidence: T::Hash[String, T::Array[Evidence]], identity: Identity)
          .returns(T::Array[Hit])
      }
      def resolve_upstream(id_evidence, identity)
        own = own_evidence(identity)
        hits = T.let([], T::Array[Hit])

        id_evidence.each do |id, evidence|
          record = fetch_vulnerability(id)
          next if record.nil?

          upstream_cves = (record.upstream + record.related).grep(CVE_ID).uniq
          if record.cve_ids.any? || upstream_cves.empty?
            hits << Hit.new(vulnerability: record, evidence:)
            next
          end

          upstream_cves.each do |cve|
            upstream_record = fetch_vulnerability(cve)
            next if upstream_record.nil?

            hits << Hit.new(vulnerability: upstream_record, evidence: evidence + own)
          end
        end

        hits
      end

      # Evidence rows pointing at our own identity keys (git repo, primary
      # registry package) with the formula/package version as subject. Attached
      # to distro-resolved upstream hits so {#range_status} can evaluate the
      # upstream CVE record's `affected[]` against something comparable.
      sig { params(identity: Identity).returns(T::Array[Evidence]) }
      def own_evidence(identity)
        result = T.let([], T::Array[Evidence])
        if (repo = identity.git_repo)
          result << Evidence.new(strategy: :distro, ecosystem: "GIT", name: repo,
                                 subject_version: identity.git_tag, key: "upstream:#{repo}").freeze
        end
        if (pkg = identity.primary_package)
          result << Evidence.new(strategy: :distro, ecosystem: pkg.ecosystem, name: pkg.name,
                                 subject_version: pkg.version, key: "upstream:#{pkg.purl}").freeze
        end
        result
      end

      # Bulk mode (the `--all` sweep) trusts the published index; only a
      # single-formula run (the PR bot, or an explicit named check) may hit the
      # live Repology API for a formula the index doesn't yet cover.
      sig { params(name: String).returns(Repology::DistroMap) }
      def distro_packages_for(name)
        indexed = repology.distro_packages_for(name)
        return indexed if indexed.any? || @bulk

        Repology.lookup(name)
      rescue CachedFeed::Error => e
        odebug "Repology lookup for #{name} failed: #{e.message}"
        {}
      end

      # OSV `querybatch` returns id/modified stubs; the full record is fetched
      # once per id and cached across formulae.
      sig { params(id: String).returns(T.nilable(Vulnerability)) }
      def fetch_vulnerability(id)
        @vuln_cache.fetch(id) do
          @vuln_cache[id] = begin
            Vulnerability.new(OSV.vulnerability(id))
          rescue OSV::Error => e
            odebug "OSV.vulnerability(#{id}) failed: #{e.message}"
            nil
          end
        end
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

      # Evaluate `hit` against the version we ship, trying each evidence in
      # precision order. Returns the first {Vulnerability::RangeStatus} that a
      # comparable range yields, or `nil` if no evidence produced a checkable
      # answer (e.g. a GIT-only record with commit-SHA ranges, or a distro-only
      # hit whose upstream CVE has no `affected[]` matching our identity).
      sig { params(hit: Hit).returns(T.nilable(Vulnerability::RangeStatus)) }
      def range_status(hit)
        hit.evidence.each do |ev|
          status = case ev.strategy
          when :cpansa
            adv = ev.advisory
            CPANSec.range_status(adv, ev.subject_version) if adv && ev.subject_version
          else
            next unless ev.subject_version

            hit.vulnerability.range_status(ev.ecosystem, ev.name, ev.subject_version)
          end
          return status if status
        end
        nil
      end

      # Emit a candidate `BREW-*` OSV record for `hit` against `formula`.
      #
      # `first_fixed` is the {PkgVersion} at which Homebrew first shipped a fix
      # (from {#first_fixed_version} or a hand-set value). Otherwise
      # {#range_status} is consulted: `affected? == false` sets
      # `fixed: pkg_version` and `ecosystem_specific.fix: "bump"`;
      # `affected? == true` (or no comparable range) emits no `fixed` event and
      # `fix: null`. As with {OsvExport.record_for}, {OsvExport.merge_existing}
      # preserves on-disk `ranges` on rewrite so a hand-corrected boundary
      # sticks.
      sig {
        params(formula: Formula, hit: Hit, first_fixed: T.nilable(String), now: Time)
          .returns(T::Hash[Symbol, T.untyped])
      }
      def to_brew_record(formula, hit, first_fixed: nil, now: Time.now.utc)
        vuln = hit.vulnerability
        timestamp = now.strftime("%Y-%m-%dT%H:%M:%SZ")
        status = range_status(hit)

        fixed = first_fixed
        fixed ||= formula.pkg_version.to_s if status && !status.affected?
        events = T.let([{ introduced: "0" }], T::Array[T::Hash[Symbol, String]])
        events << { fixed: } if fixed

        record = T.let({
          schema_version:    OsvExport::SCHEMA_VERSION,
          id:                "#{OsvExport::ID_PREFIX}-#{formula.name}-#{hit.canonical_id}",
          published:         timestamp,
          modified:          timestamp,
          upstream:          vuln.identifiers,
          affected:          [affected_entry(formula, hit, events, fixed, status)],
          database_specific: {
            source:            "matched",
            strategy:          hit.strategy.to_s,
            confidence:        confidence_for(hit, status),
            upstream_evidence: hit.evidence.map { |e| e.to_h.except(:advisory).compact },
          },
        }, T::Hash[Symbol, T.untyped])

        record[:summary] = vuln.summary if vuln.summary
        record[:details] = vuln.details if vuln.details
        record[:severity] = vuln.severity_entries if vuln.severity_entries.any?
        if (refs = vuln.references).any?
          record[:references] = refs.uniq { |r| [r["type"], URI::RFC2396_PARSER.unescape(r["url"].to_s)] }
        end

        record
      end

      sig {
        params(hit: Hit, status: T.nilable(Vulnerability::RangeStatus)).returns(String)
      }
      def confidence_for(hit, status)
        base = CONFIDENCE.fetch(hit.strategy)
        return base if status

        # No comparable range: the reviewer must set the boundary by hand.
        (base == "high") ? "medium" : "low"
      end

      sig {
        params(formula: Formula, hit: Hit, events: T::Array[T::Hash[Symbol, String]],
               fixed: T.nilable(String), status: T.nilable(Vulnerability::RangeStatus))
          .returns(T::Hash[Symbol, T.untyped])
      }
      def affected_entry(formula, hit, events, fixed, status)
        eco = T.let({ fix: fixed ? "bump" : nil }, T::Hash[Symbol, T.nilable(String)])
        eco[:upstream_fixed_in] = status.fixed_in if status&.fixed_in
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

      # Walk homebrew-core git history (newest first) via {FormulaVersions} and
      # return the `pkg_version` at the oldest revision where the subject was
      # still at or past `upstream_fixed_in`. Returns nil when the current
      # version is not yet fixed. The rev-list and per-revision loads are
      # cached per formula so subsequent hits reuse both.
      sig { params(formula: Formula, hit: Hit).returns(T.nilable(String)) }
      def first_fixed_version(formula, hit)
        status = range_status(hit)
        return if status.nil? || status.affected?
        return unless (upstream_fixed = status.fixed_in)

        threshold = Version.new(upstream_fixed)
        resource = hit.resource
        fv = @formula_versions[formula.name] ||= FormulaVersions.new(formula)
        revs = @formula_rev_lists[formula.name] ||=
          [].tap { |a| fv.rev_list("HEAD") { |rev, entry| a << [rev, entry] } }

        last_fixed = T.let(formula.pkg_version.to_s, T.nilable(String))
        revs.each do |rev, entry|
          old_fixed = fv.formula_at_revision(rev, entry) do |old|
            subject = subject_version(old, resource)
            old.pkg_version.to_s if subject && subject >= threshold
          end
          return last_fixed if old_fixed.nil?

          last_fixed = old_fixed
        end
        last_fixed
      end

      sig { params(formula: Formula, resource: T.nilable(String)).returns(T.nilable(Version)) }
      def subject_version(formula, resource)
        if resource
          begin
            formula.resource(resource)&.version
          rescue ResourceMissingError
            nil
          end
        else
          formula.version
        end
      end
    end
  end
end
