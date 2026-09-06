# typed: strict
# frozen_string_literal: true

require "formula_versions"

module Homebrew
  module Vulns
    # Walks a formula's tap history newest first via {FormulaVersions}, caching
    # the rev-list and the per-revision loads per formula so every advisory for
    # the same formula reuses them.
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
        return :history_unavailable if formula.tap!.shallow?

        fv = @formula_versions[formula.name] ||= FormulaVersions.new(formula)
        revs = @rev_lists[formula.name] ||=
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
