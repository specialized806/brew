# typed: strict
# frozen_string_literal: true

module RuboCop
  module Cop
    module Cask
      # This cop checks for `uninstall`/`zap` wildcards with nothing to match on,
      # e.g. `quit: "*"`, which would target every running application.
      class UninstallWildcard < Base
        MESSAGE = "Include part of an ID alongside a wildcard, otherwise everything is matched."
        WILDCARD_DIRECTIVES = [:launchctl, :quit, :signal].freeze

        RESTRICT_ON_SEND = [:uninstall, :zap].freeze

        sig { params(node: RuboCop::AST::SendNode).void }
        def on_send(node)
          node.each_descendant(:pair) do |pair|
            next unless pair.key.sym_type?
            next unless WILDCARD_DIRECTIVES.include?(pair.key.value)

            values = pair.value.str_type? ? [pair.value] : pair.value.each_descendant(:str).to_a
            values.each do |value|
              next unless unbounded_wildcard?(value.value)

              add_offense(value, message: MESSAGE)
            end
          end
        end

        private

        # A wildcard needs at least one character of an ID to match against.
        sig { params(value: String).returns(T::Boolean) }
        def unbounded_wildcard?(value)
          value.include?("*") && !value.match?(/[[:alnum:]]/)
        end
      end
    end
  end
end
