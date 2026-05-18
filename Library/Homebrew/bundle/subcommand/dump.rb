# typed: strict
# frozen_string_literal: true

require "abstract_subcommand"
require "bundle/extensions/extension"

require "bundle/dumper"
module Homebrew
  module Cmd
    class Bundle < Homebrew::AbstractCommand
      class DumpSubcommand < Homebrew::AbstractSubcommand
        subcommand_args do
          extensions = Homebrew::Bundle.extensions
          usage_banner <<~EOS
            `brew bundle dump`:
            Write all installed casks/formulae/images/taps into a `Brewfile` in the current directory or to a custom file specified with the `--file` option. This is useful as an installed-state snapshot and can be kept in version control and diffed.
          EOS
          named_args :none
          switch "--install",
                 description: "Run `install` before dumping dependencies."
          switch "-f", "--force",
                 description: "Overwrite an existing `Brewfile`."
          switch "--formula", "--formulae", "--brews",
                 description: "Dump Homebrew formula dependencies."
          switch "--cask", "--casks",
                 description: "Dump Homebrew cask dependencies."
          switch "--tap", "--taps",
                 description: "Dump Homebrew tap dependencies."
          extensions.select(&:dump_supported?).each do |extension|
            switch "--#{extension.flag}",
                   description: extension.switch_description("Dump #{extension.banner_name}.")
          end
          extensions.select(&:dump_disable_supported?).each do |extension|
            switch "--no-#{extension.flag}",
                   description: extension.dump_disable_description,
                   env:         extension.dump_disable_env
          end
          switch "--describe",
                 description: "Add a description comment above each line, unless the " \
                              "dependency does not have a description.",
                 env:         :bundle_describe
          switch "--no-restart",
                 description: "Do not add `restart_service` to formula lines."
        end

        sig { override.void }
        def run
          Homebrew::Bundle::Dumper.dump_brewfile(
            global:          context.global,
            file:            context.file,
            describe:        args.describe?,
            force:           context.force,
            no_restart:      args.no_restart?,
            taps:            args.taps? || context.no_type_args,
            formulae:        args.formulae? || context.no_type_args,
            casks:           args.casks? || context.no_type_args,
            extension_types: context.extensions.select(&:dump_supported?).to_h do |extension|
              disabled = extension.dump_disable_supported? &&
                         context.extension_dump_disabled?(args, extension)
              enabled = !disabled &&
                        (context.extension_selected?(args, extension) || context.no_type_args)
              [extension.type, enabled]
            end,
          )
        end
      end
    end
  end
end
