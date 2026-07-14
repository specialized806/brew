# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "formula"
require "vulns/osv_export"

module Homebrew
  module DevCmd
    class GenerateVulnsAdvisories < AbstractCommand
      cmd_args do
        description <<~EOS
          Generate OSV-schema advisory records for the `Homebrew` ecosystem from
          `homebrew/core` formula patch `resolves` annotations, for
          <https://github.com/Homebrew/homebrew-advisory-database>.

          Records are written to <directory>.
        EOS
        switch "-n", "--dry-run",
               description: "List the records that would be generated without writing files or querying OSV.dev."

        named_args :directory, number: 1

        hide_from_man_page!
      end

      sig { override.void }
      def run
        tap = CoreTap.instance
        raise TapUnavailableError, tap.name unless tap.installed?

        dir = args.named.first

        Formulary.enable_factory_cache!
        annotated = Homebrew.with_no_api_env do
          latest_macos = MacOSVersion.new((HOMEBREW_MACOS_NEWEST_UNSUPPORTED.to_i - 1).to_s).to_sym
          Homebrew::SimulateSystem.with(os: latest_macos, arch: :arm) do
            tap.formula_names.filter_map do |name|
              formula = Formulary.factory(name)
              patches = all_variation_patches(formula)
              [formula, patches] if Homebrew::Vulns::Scanner.resolved_ids(patches).any?
            rescue
              onoe "Error loading formula '#{name}'."
              raise
            end
          end
        end
        ohai "#{annotated.size} formulae with security `resolves` annotations"

        if args.dry_run?
          annotated.each do |formula, patches|
            Homebrew::Vulns::Scanner.resolved_ids(patches).each do |vuln_id|
              puts "#{Homebrew::Vulns::OsvExport::ID_PREFIX}-#{formula.name}-#{vuln_id}"
            end
          end
          return
        end

        written = Homebrew::Vulns::OsvExport.run(annotated, T.must(dir))
        written.each { |p| puts "  wrote #{p}" } if args.verbose?
        ohai "#{written.size} records written to #{dir}"
      end

      # `Formula#serialized_patches` reflects the currently simulated OS and
      # architecture; a `patch` inside e.g. `on_linux` is invisible under
      # `SimulateSystem.with(os: :sequoia)`. Collect the union of the base
      # `patches` array and every OS/arch variation from
      # `Formula#to_hash_with_variations` so platform-gated `resolves`
      # annotations are exported.
      sig { params(formula: Formula).returns(T::Array[T::Hash[String, T.untyped]]) }
      def all_variation_patches(formula)
        hash = formula.to_hash_with_variations
        base = hash.fetch("patches")
        variation_patches = hash.fetch("variations").values.filter_map { |v| v["patches"] }
        (base + variation_patches.flatten(1)).uniq
      end
    end
  end
end
