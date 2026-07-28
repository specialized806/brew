# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "formula"
require "vulns/match"

module Homebrew
  module DevCmd
    class AdvisoryMatch < AbstractCommand
      cmd_args do
        description <<~EOS
          Match <formula> against OSV.dev (GIT, language-registry and distro
          ecosystems) and CPANSA to produce candidate `BREW-*` advisory records
          for <https://github.com/Homebrew/advisory-database>.

          This is authoring-time tooling for the advisory-database CI and the
          `homebrew-core` PR bot; use `brew vulns` to scan installed formulae.
        EOS
        switch "--all",
               description: "Match every formula in `homebrew/core`."
        switch "--index",
               description: "Emit the formula-identity index as JSON and exit."
        switch "--json",
               description: "Output candidate records as a JSON array."
        flag   "--output=",
               description: "Write each record to <directory> as " \
                            "`BREW-<formula>-<id>.json`, preserving existing " \
                            "`published`/`ranges` fields."
        switch "--no-history",
               description: "Skip the `FormulaVersions` walk for the `fixed` " \
                            "boundary; use the current `pkg_version` instead."
        conflicts "--all", "--index"
        conflicts "--index", "--json"
        conflicts "--index", "--output"

        named_args [:formula]

        hide_from_man_page!
      end

      sig { override.void }
      def run
        Formulary.enable_factory_cache!
        Homebrew.with_no_api_env do
          latest_macos = MacOSVersion.new((HOMEBREW_MACOS_NEWEST_UNSUPPORTED.to_i - 1).to_s).to_sym
          Homebrew::SimulateSystem.with(os: latest_macos, arch: :arm) do
            matcher = Homebrew::Vulns::Match.new
            next emit_index(matcher) if args.index?

            records = each_formula.flat_map { |f| records_for(matcher, f) }
            emit(records)
          end
        end
      end

      sig { returns(T::Enumerator[Formula]) }
      def each_formula
        return args.named.to_resolved_formulae.each unless args.all?

        raise UsageError, "`--all` does not take named arguments" if args.named.any?

        tap = CoreTap.instance
        raise TapUnavailableError, tap.name unless tap.installed?

        Enumerator.new do |y|
          tap.formula_names.each do |name|
            y << Formulary.factory(name)
          rescue => e
            onoe "Error loading formula '#{name}': #{e}"
          end
        end
      end

      sig { params(matcher: Homebrew::Vulns::Match, formula: Formula).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
      def records_for(matcher, formula)
        hits = matcher.advisories_for(formula)
        report(formula, hits) unless args.json? || args.output
        hits.map do |hit|
          first_fixed = matcher.first_fixed_version(formula, hit) unless args.no_history?
          matcher.to_brew_record(formula, hit, first_fixed:)
        end
      rescue Homebrew::Vulns::OSV::Error => e
        onoe "OSV query for #{formula.name} failed: #{e.message}"
        Homebrew.failed = true
        []
      end

      sig { params(formula: Formula, hits: T::Array[Homebrew::Vulns::Match::Hit]).void }
      def report(formula, hits)
        ohai "#{formula.name} #{formula.pkg_version}"
        if hits.empty?
          puts "  No advisories matched."
          return
        end
        hits.sort_by { |h| [-h.vulnerability.severity_level, h.canonical_id] }.each do |hit|
          v = hit.vulnerability
          fixed = v.fixed_versions.first
          puts "  #{hit.canonical_id} [#{hit.strategy}, " \
               "#{Homebrew::Vulns::Match::CONFIDENCE.fetch(hit.strategy)}] " \
               "#{v.severity_display} #{v.summary&.slice(0, 60)}" \
               "#{" (upstream fixed #{fixed})" if fixed}" \
               "#{" (resource: #{hit.resource})" if hit.resource}"
        end
      end

      sig { params(records: T::Array[T::Hash[Symbol, T.untyped]]).void }
      def emit(records)
        if (dir = args.output)
          FileUtils.mkdir_p(dir)
          written = 0
          records.each do |record|
            path = File.join(dir, "#{record.fetch(:id)}.json")
            merged = Homebrew::Vulns::OsvExport.merge_existing(path, record)
            next if merged.nil?

            File.write(path, "#{JSON.pretty_generate(merged)}\n")
            puts "  wrote #{path}" if args.verbose?
            written += 1
          end
          ohai "#{written} records written to #{dir} (#{records.size - written} unchanged)"
        elsif args.json?
          puts JSON.pretty_generate(records)
        else
          ohai "#{records.size} candidate records"
        end
      end

      sig { params(matcher: Homebrew::Vulns::Match).void }
      def emit_index(matcher)
        tap = CoreTap.instance
        raise TapUnavailableError, tap.name unless tap.installed?

        index = tap.formula_names.each_with_object({}) do |name, h|
          identity = matcher.identify(Formulary.factory(name))
          next unless identity.identifiable?

          h[name] = {
            git_repo:          identity.git_repo,
            git_tag:           identity.git_tag,
            primary_package:   identity.primary_package&.to_h,
            resource_packages: identity.resource_packages.transform_values(&:to_h),
            distro_packages:   identity.distro_packages,
          }.compact
        rescue => e
          onoe "Error loading formula '#{name}': #{e}"
        end
        puts JSON.pretty_generate(index)
      end
    end
  end
end
