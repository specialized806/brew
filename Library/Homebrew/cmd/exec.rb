# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "shell_command"

module Homebrew
  module Cmd
    class Exec < AbstractCommand
      include ShellCommand

      cmd_args do
        usage_banner <<~EOS
          `exec`, `x` [`--skip-update`] [`+`<formula> ...] <command> [<args> ...]

          Run a Homebrew executable, installing its formula if needed.
        EOS

        switch "--skip-update",
               description: "Skip updating the executables database if any version exists on disk, no matter how old."

        named_args min: 1
      end
    end
  end
end
