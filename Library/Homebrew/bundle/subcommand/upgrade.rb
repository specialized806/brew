# typed: strict
# frozen_string_literal: true

require "abstract_subcommand"

module Homebrew
  module Cmd
    class Bundle < Homebrew::AbstractCommand
      class UpgradeSubcommand < Homebrew::AbstractSubcommand
        subcommand_args do
          usage_banner <<~EOS
            `brew bundle upgrade`:
            Shorthand for `brew bundle install --upgrade`.
          EOS
          named_args :none
          switch "--upgrade",
                 description: "Run `brew upgrade` on outdated dependencies, " \
                              "even if `$HOMEBREW_BUNDLE_NO_UPGRADE` is set."
          flag   "--upgrade-formulae=", "--upgrade-formula=",
                 description: "Run `brew upgrade` on any of these comma-separated formulae, " \
                              "even if `$HOMEBREW_BUNDLE_NO_UPGRADE` is set."
          # odeprecated: change default for 5.2 and document HOMEBREW_BUNDLE_JOBS
          flag "--jobs=",
               description: "Run up to this many formula installations in parallel. " \
                            "Defaults to 1 (sequential). Use `auto` for the number of CPU cores (max 4)."
        end

        sig { override.void }
        def run
          InstallSubcommand.new(args, context:).run
        end
      end
    end
  end
end
