# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "formula"

module Homebrew
  module Cmd
    class Vulns < AbstractCommand
      SEVERITIES = %w[low medium high critical].freeze

      cmd_args do
        description <<~EOS
          Check <formula> for known security vulnerabilities using the OSV.dev database.

          With no arguments, all installed formulae are checked.
        EOS
        switch "--eval-all",
               description: "Check every available formula, whether installed or not.",
               env:         :eval_all
        switch "-d", "--deps",
               description: "Also check the dependencies of named formulae."
        switch "--no-ignore-patches",
               description: "Report vulnerabilities even when a formula patch resolves them."
        flag   "--brewfile=",
               description: "Check formulae listed in the given Brewfile."
        flag   "-s", "--severity=",
               description: "Only report findings at or above: `low`, `medium`, `high`, `critical`."
        flag   "-m", "--max-summary=",
               description: "Truncate summaries to <n> characters (default 60, 0 for no limit)."
        switch "-j", "--json",
               description: "Output JSON."

        conflicts "--eval-all", "--brewfile"

        named_args :formula
      end

      sig { override.void }
      def run
        require "vulns"

        summary_width = max_summary

        results = Homebrew::Vulns::Scanner.new(
          formulae,
          ignore_patches: !args.no_ignore_patches?,
          min_severity:,
        ).scan

        if args.json?
          Homebrew::Vulns::Output.json(results)
        else
          Homebrew::Vulns::Output.text(results, max_summary: summary_width)
        end

        if results.outdated_without_sbom.any?
          opoo <<~EOS
            The installed source of #{results.outdated_without_sbom.sort.join(", ")} could not be determined
            (older than the current formula and no SBOM was written at install time). Results above reflect
            the current formula version, not what is installed. Run `brew upgrade` for accurate results.
          EOS
          Homebrew.failed = true
        end
        Homebrew.failed = true if results.any_open?
      end

      sig { returns(T::Array[Formula]) }
      def formulae
        list =
          if args.eval_all?
            Formula.all(eval_all: true)
          elsif (brewfile = args.brewfile)
            require "bundle/brewfile"
            Homebrew::Bundle::Brewfile.read(file: brewfile).entries
                                      .select { |e| e.type == :brew }
                                      .map { |e| Formulary.resolve(e.name) }
          elsif args.named.any?
            args.named.to_resolved_formulae
          else
            Formula.installed
          end
        list += list.flat_map { |f| f.recursive_dependencies.map(&:to_formula) } if args.deps?
        list.uniq(&:full_name)
      end

      sig { returns(T.nilable(Symbol)) }
      def min_severity
        raw = args.severity
        return if raw.nil?

        raw = raw.downcase
        raise UsageError, "`--severity` must be one of: #{SEVERITIES.join(", ")}" unless SEVERITIES.include?(raw)

        raw.to_sym
      end

      sig { returns(Integer) }
      def max_summary
        raw = args.max_summary
        return Homebrew::Vulns::Output::DEFAULT_MAX_SUMMARY if raw.nil?

        raise UsageError, "`--max-summary` must be a non-negative integer" unless raw.match?(/\A\d+\z/)

        raw.to_i
      end
    end
  end
end
