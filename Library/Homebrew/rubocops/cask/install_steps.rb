# typed: strict
# frozen_string_literal: true

require "rubocops/shared/install_steps_helper"

module RuboCop
  module Cop
    module Cask
      # This cop checks declarative install step usage.
      class InstallSteps < Base
        include CaskHelp
        include ::RuboCop::Cop::InstallStepsHelper

        INSTALL_STEP_PAIRS = T.let(
          {
            preflight:            :preflight_steps,
            postflight:           :postflight_steps,
            uninstall_preflight:  :uninstall_preflight_steps,
            uninstall_postflight: :uninstall_postflight_steps,
          }.freeze,
          T::Hash[Symbol, Symbol],
        )

        sig { override.params(cask_block: RuboCop::Cask::AST::CaskBlock).void }
        def on_cask(cask_block)
          stanzas = cask_block.stanzas
          INSTALL_STEP_PAIRS.each do |flight_block, steps_block|
            next unless (flight_stanza = stanzas.find { |stanza| stanza.stanza_name == flight_block })
            next unless (steps_stanza = stanzas.find { |stanza| stanza.stanza_name == steps_block })

            add_offense(steps_stanza.source_range,
                        message: "`#{flight_stanza.stanza_name}` and `#{steps_block}` cannot both be used.")
          end

          stanzas.each do |stanza|
            next unless INSTALL_STEP_PAIRS.value?(stanza.stanza_name)
            next unless stanza.method_node.block_type?
            next unless (offense_node = install_step_block_offense_node(T.cast(stanza.method_node,
                                                                               RuboCop::AST::BlockNode)))

            add_offense(offense_node, message: STEP_BLOCK_MSG)
          end
        end
      end
    end
  end
end
