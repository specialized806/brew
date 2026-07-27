# typed: strict
# frozen_string_literal: true

require "vulns/cpan_sec"
require "vulns/identify"
require "vulns/osv"
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

      Identity = Struct.new(
        :git_repo, :git_tag, :primary_package, :resource_packages, :distro_packages,
        keyword_init: true
      ) do
        extend T::Sig

        sig { returns(T::Boolean) }
        def any?
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

          @vulnerability = T.let(vulnerability, Vulnerability)
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
        @repology = T.let(repology, T.nilable(Repology))
        @cpan_sec = T.let(cpan_sec, T.nilable(CPANSec))
        @vuln_cache = T.let({}, T::Hash[String, T.nilable(T::Hash[String, T.untyped])])
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
        return [] unless identity.any?

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
