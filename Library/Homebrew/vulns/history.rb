# typed: strict
# frozen_string_literal: true

require "formula_versions"
require "simulate_system"

module Homebrew
  module Vulns
    # Walks a formula's tap history newest first via {FormulaVersions}. Each
    # instance shares Git facts across platforms for a fixed tap history,
    # while loaded formulae remain specific to the simulated platform.
    #
    # History that cannot be trusted fails closed: a shallow clone, a formula
    # file with no git history and a revision that cannot be loaded all end the
    # walk with `:history_unavailable` so callers skip the candidate rather
    # than inventing a boundary.
    class History
      sig { void }
      def initialize
        @formula_versions = T.let({}, T::Hash[String, FormulaVersions])
        @rev_lists = T.let({}, T::Hash[String, T::Array[[String, String]]])
        @shallow_taps = T.let({}, T::Hash[String, T::Boolean])
      end

      # Yield each loadable historical revision of `formula`, newest first,
      # until the block returns a result. Returns that result,
      # `:history_unavailable` when the history cannot be trusted or `nil` once
      # every revision has been visited.
      sig {
        params(formula: Formula,
               _block:  T.proc.params(old: Formula).returns(T.nilable(T.any(String, Symbol))))
          .returns(T.nilable(T.any(String, Symbol)))
      }
      def walk(formula, &_block)
        tap = formula.tap!
        tap_key = tap.path.to_s
        return :history_unavailable if @shallow_taps.fetch(tap_key) { @shallow_taps[tap_key] = tap.shallow? }

        tap_path = formula.tap_path.to_s
        fv = @formula_versions["#{tap_path}:#{SimulateSystem.current_os}:#{SimulateSystem.current_arch}"] ||=
          FormulaVersions.new(formula)
        revs = @rev_lists[tap_path] ||=
          [].tap { |a| fv.rev_list("HEAD") { |rev, entry| a << [rev, entry] } }
        return :history_unavailable if revs.empty?

        revs.each do |rev, entry|
          # Wrap the verdict so keeping the walk going (`nil`) stays
          # distinguishable from a revision that failed to load.
          verdict = fv.formula_at_revision(rev, entry) { |old| [yield(old)] }
          return :history_unavailable if verdict.nil?

          result = verdict.fetch(0)
          return result unless result.nil?
        end
        nil
      end
    end
  end
end
