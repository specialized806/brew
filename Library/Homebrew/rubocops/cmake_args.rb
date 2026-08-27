# typed: strict
# frozen_string_literal: true

require "rubocops/extend/formula_cop"

module RuboCop
  module Cop
    module FormulaAudit
      # This cop checks that CMake source and build directories are explicit.
      class CMakeArgs < FormulaCop
        extend AutoCorrector

        MSG = "Use explicit `-S` and `-B` arguments for CMake."

        sig { override.params(formula_nodes: FormulaNodes).void }
        def audit_formula(formula_nodes)
          return if (body_node = formula_nodes.body_node).nil?

          find_every_method_call_by_name(body_node, :system).each do |method|
            next if method.receiver

            args = parameters(method)
            command, source_dir = args
            next unless node_equals?(command, "cmake")
            # A leading argument that isn't an option is a positional source directory,
            # which implicitly builds in the working directory.
            next unless source_dir.is_a?(RuboCop::AST::StrNode)
            next if source_dir.value.start_with?("-")
            # Leave calls that already pass an explicit directory alone, otherwise
            # the correction below would add a second `-B` argument.
            next if args.any? { |arg| node_equals?(arg, "-S") || node_equals?(arg, "-B") }

            offending_node(source_dir)
            problem MSG do |corrector|
              corrector.replace(source_dir.source_range, %Q("-S", #{source_dir.source}, "-B", "."))
            end
          end
        end
      end
    end
  end
end
