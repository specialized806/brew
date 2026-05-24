# typed: strict
# frozen_string_literal: true

require "rubocops/extend/formula_cop"
require "rubocops/shared/install_steps_helper"

module RuboCop
  module Cop
    module FormulaAudit
      # This cop checks declarative install step usage.
      class InstallSteps < FormulaCop
        include InstallStepsHelper

        CONFLICT_MSG = "`post_install` and `post_install_steps` cannot both be used."

        sig { override.params(formula_nodes: FormulaNodes).void }
        def audit_formula(formula_nodes)
          return if (body_node = formula_nodes.body_node).nil?

          post_install_steps_block = find_block(body_node, :post_install_steps)
          post_install_method = find_method_def(body_node, :post_install)
          if post_install_steps_block && post_install_method
            offending_node(post_install_steps_block)
            problem CONFLICT_MSG
          end

          audit_step_block(post_install_steps_block)
        end

        private

        sig { params(block_node: T.nilable(RuboCop::AST::BlockNode)).void }
        def audit_step_block(block_node)
          return unless (offense_node = install_step_block_offense_node(block_node))

          offending_node(offense_node)
          problem STEP_BLOCK_MSG
        end
      end
    end
  end
end
