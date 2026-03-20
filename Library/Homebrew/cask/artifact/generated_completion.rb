# typed: strict
# frozen_string_literal: true

require "cask/artifact/abstract_artifact"
require "extend/hash/keys"

module Cask
  module Artifact
    # Artifact corresponding to the `generate_completions_from_executable` stanza.
    class GeneratedCompletion < AbstractArtifact
      SUPPORTED_SHELLS = T.let([:bash, :zsh, :fish, :pwsh].freeze, T::Array[Symbol])

      sig { override.returns(Symbol) }
      def self.dsl_key
        :generate_completions_from_executable
      end

      sig {
        params(
          cask:                   Cask,
          args:                   T.any(Pathname, String),
          base_name:              T.nilable(String),
          shell_parameter_format: T.nilable(T.any(Symbol, String)),
          shells:                 T.nilable(T::Array[Symbol]),
        ).returns(T.attached_class)
      }
      def self.from_args(cask, *args, base_name: nil, shell_parameter_format: nil, shells: nil)
        raise CaskInvalidError.new(cask.token, "'#{dsl_key}' requires at least one command") if args.empty?

        commands = args.to_a
        resolved_shells = shells || default_completion_shells(shell_parameter_format)

        unsupported_shells = resolved_shells - SUPPORTED_SHELLS
        unless unsupported_shells.empty?
          raise CaskInvalidError.new(
            cask.token,
            "'#{dsl_key}' does not support shell(s): #{unsupported_shells.join(", ")}",
          )
        end

        new(
          cask,
          commands,
          base_name:,
          shell_parameter_format:,
          shells:                 resolved_shells,
        )
      end

      sig {
        params(
          cask:                   Cask,
          commands:               T::Array[T.any(Pathname, String)],
          base_name:              T.nilable(String),
          shell_parameter_format: T.nilable(T.any(Symbol, String)),
          shells:                 T::Array[Symbol],
        ).void
      }
      def initialize(cask, commands, base_name:, shell_parameter_format:, shells:)
        super(cask, *commands, base_name:, shell_parameter_format:, shells:)

        @commands = T.let(commands, T::Array[T.any(Pathname, String)])
        @base_name = T.let(base_name, T.nilable(String))
        @shell_parameter_format = T.let(shell_parameter_format, T.nilable(T.any(Symbol, String)))
        @shells = T.let(shells, T::Array[Symbol])
        @resolved_base_name = T.let(nil, T.nilable(String))
      end

      sig { returns(T::Array[T.any(Pathname, String)]) }
      attr_reader :commands

      sig { returns(T.nilable(String)) }
      attr_reader :base_name

      sig { returns(T.nilable(T.any(Symbol, String))) }
      attr_reader :shell_parameter_format

      sig { returns(T::Array[Symbol]) }
      attr_reader :shells

      sig { override.returns(String) }
      def summarize
        "#{commands.join(" ")} (base_name: #{resolved_base_name}, shells: #{shells.join(", ")})"
      end

      sig { params(_options: T.untyped).void }
      def install_phase(**_options)
        executable = staged_path_join_executable(T.must(commands.first))

        shells.each do |shell|
          popen_read_env = { "SHELL" => shell.to_s }
          shell_parameter = completion_shell_parameter(shell, executable.to_s, popen_read_env)

          popen_read_args = commands.dup
          popen_read_args[0] = executable
          popen_read_args.concat(Array(shell_parameter))

          popen_read_options = T.let({}, T::Hash[Symbol, Symbol])
          popen_read_options[:err] = :err unless ENV["HOMEBREW_STDERR"]

          script_path = completion_script_path(shell)
          script_path.dirname.mkpath
          script_path.write(::Utils.safe_popen_read(popen_read_env, *popen_read_args, **popen_read_options))
        rescue => e
          opoo "Failed to generate #{shell} completions from #{executable}: #{e}"
        end
      end

      sig { params(command: T.class_of(SystemCommand), _options: T.untyped).void }
      def uninstall_phase(command: SystemCommand, **_options)
        shells.each do |shell|
          path = completion_script_path(shell)
          next unless path.exist?

          Utils.gain_permissions_remove(path, command:)
        rescue => e
          opoo "Failed to remove #{shell} generated completions: #{e}"
        end
      end

      private

      sig { returns(String) }
      def resolved_base_name
        @resolved_base_name ||= T.let(begin
          executable = staged_path_join_executable(T.must(commands.first))
          name = base_name || File.basename(executable.to_s)
          name = cask.token if name.empty?
          name
        end, T.nilable(String))
        @resolved_base_name
      end

      sig { params(shell: Symbol).returns(Pathname) }
      def completion_script_path(shell)
        case shell
        when :bash
          config.bash_completion/resolved_base_name
        when :zsh
          config.zsh_completion/"_#{resolved_base_name}"
        when :fish
          config.fish_completion/"#{resolved_base_name}.fish"
        when :pwsh
          HOMEBREW_PREFIX/"share/pwsh/completions"/"_#{resolved_base_name}.ps1"
        else
          raise ArgumentError, "unsupported shell: #{shell}"
        end
      end

      sig {
        params(
          shell:      Symbol,
          executable: String,
          env:        T::Hash[String, String],
        ).returns(T.nilable(T.any(String, T::Array[String])))
      }
      def completion_shell_parameter(shell, executable, env)
        shell_parameter = (shell == :pwsh) ? "powershell" : shell.to_s

        case shell_parameter_format
        when nil
          shell_parameter
        when :arg
          "--shell=#{shell_parameter}"
        when :clap
          env["COMPLETE"] = shell_parameter
          nil
        when :click
          prog_name = File.basename(executable).upcase.tr("-", "_")
          env["_#{prog_name}_COMPLETE"] = "#{shell_parameter}_source"
          nil
        when :cobra
          ["completion", shell_parameter]
        when :flag
          "--#{shell_parameter}"
        when :none
          nil
        when :typer
          env["_TYPER_COMPLETE_TEST_DISABLE_SHELL_DETECTION"] = "1"
          ["--show-completion", shell_parameter]
        else
          "#{shell_parameter_format}#{shell}"
        end
      end

      sig { params(format: T.nilable(T.any(Symbol, String))).returns(T::Array[Symbol]) }
      def self.default_completion_shells(format)
        case format
        when :cobra, :typer
          [:bash, :zsh, :fish, :pwsh]
        else
          [:bash, :zsh, :fish]
        end
      end
      private_class_method :default_completion_shells
    end
  end
end
