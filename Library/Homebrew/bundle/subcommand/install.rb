# typed: strict
# frozen_string_literal: true

require "abstract_subcommand"

require "bundle/brewfile"
require "bundle/installer"
module Homebrew
  module Cmd
    class Bundle < Homebrew::AbstractCommand
      class InstallSubcommand < Homebrew::AbstractSubcommand
        subcommand_args default: true do
          usage_banner <<~EOS
            `brew bundle` [`install`]:
            Install and upgrade (by default) all dependencies from the `Brewfile`.

            Use this to restore a recorded installed state from a `Brewfile`.

            You can specify the `Brewfile` location using `--file` or by setting the `$HOMEBREW_BUNDLE_FILE` environment variable.

            You can skip the installation of dependencies by adding space-separated values to one or more of the following environment variables: `$HOMEBREW_BUNDLE_BREW_SKIP`, `$HOMEBREW_BUNDLE_CASK_SKIP`, `$HOMEBREW_BUNDLE_MAS_SKIP`, `$HOMEBREW_BUNDLE_TAP_SKIP`.
          EOS
          named_args :none
          switch "-v", "--verbose",
                 description: "Print output from commands as they are run."
          switch "--no-upgrade",
                 description: "Do not run `brew upgrade` on outdated dependencies. " \
                              "Note they may still be upgraded by `brew install` if needed.",
                 env:         :bundle_no_upgrade
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
          switch "-f", "--force",
                 description: "Run with `--force`/`--overwrite`."
          switch "--cleanup",
                 description: "Perform cleanup after installing dependencies, same as running `cleanup --force`.",
                 env:         [:bundle_install_cleanup, "--global"]
          switch "--zap",
                 description: "Use `zap` instead of `uninstall` when cleaning up casks after " \
                              "installing dependencies.",
                 depends_on:  "--cleanup"
        end

        sig { override.void }
        def run
          @dsl = Homebrew::Bundle::Brewfile.read(global: context.global, file: context.file)
          result = Homebrew::Bundle::Installer.install!(
            @dsl.entries,
            global:     context.global,
            file:       context.file,
            no_lock:    false,
            no_upgrade: context.no_upgrade,
            verbose:    context.verbose,
            force:      context.force,
            jobs:       context.jobs,
            quiet:      quiet || args.quiet?,
          )

          # Mark Brewfile formulae as installed_on_request to prevent autoremove
          # from removing them when their dependents are uninstalled
          Homebrew::Bundle.mark_as_installed_on_request!(@dsl.entries)

          result || exit(1)

          return unless cleanup

          cleanup_requested = if ENV.fetch("HOMEBREW_BUNDLE_INSTALL_CLEANUP", nil)
            args.global?
          else
            args.cleanup?
          end
          return unless cleanup_requested

          require "bundle/subcommand/cleanup"

          # Don't need to reset cleanup specifically but this resets all the dumper modules.
          Homebrew::Cmd::Bundle::CleanupSubcommand.reset!
          Homebrew::Cmd::Bundle::CleanupSubcommand.cleanup(
            global: context.global, file: context.file, zap: context.zap, force: true, dsl:,
          )
        end

        sig { returns(T.nilable(Homebrew::Bundle::Dsl)) }
        def dsl
          @dsl ||= T.let(nil, T.nilable(Homebrew::Bundle::Dsl))
          @dsl
        end
      end
    end
  end
end
