# typed: strict
# frozen_string_literal: true

require "cask/artifact/binary"
require "extend/pathname"
require "shellwords"

module Cask
  module Artifact
    # Artifact corresponding to the `command_wrapper` stanza.
    class CommandWrapper < Binary
      Arguments = T.type_alias { T.any(String, Pathname, T::Array[T.any(String, Pathname)]) }
      Environment = T.type_alias { T::Hash[T.any(String, Symbol), T.any(String, Pathname)] }

      sig { override.returns(Symbol) }
      def self.dirmethod = :binarydir

      sig {
        override.params(
          cask:    Cask,
          source:  T.any(String, Pathname),
          options: T.untyped,
        ).returns(T.attached_class)
      }
      def self.from_args(cask, source, options = nil)
        options ||= {}
        options.assert_valid_keys(:target, :content, :executable, :args, :env)
        options[:target] = Pathname(source).basename.to_s.delete_suffix(".wrapper.sh") if options[:target].blank?

        new(cask, source, **options)
      end

      sig {
        params(
          cask:       Cask,
          source:     T.any(String, Pathname),
          target:     T.any(String, Pathname),
          content:    T.nilable(String),
          executable: T.nilable(T.any(String, Pathname)),
          args:       Arguments,
          env:        Environment,
        ).void
      }
      def initialize(cask, source, target:, content: nil, executable: nil, args: [], env: {})
        if content.blank? && executable.to_s.blank?
          raise CaskInvalidError.new(cask, "'command_wrapper' requires content or executable")
        end
        if content.present? && executable.to_s.present?
          raise CaskInvalidError.new(cask, "'command_wrapper' requires content or executable, not both")
        end
        if content.present? && (args.present? || env.present?)
          raise CaskInvalidError.new(cask, "'command_wrapper' args and env require executable")
        end

        super(cask, source, target:)
        @content = T.let(content.presence, T.nilable(String))
        @executable = T.let(executable&.to_s.presence, T.nilable(String))
        @args = T.let(Array(args).map(&:to_s), T::Array[String])
        @env = T.let(env.to_h { |key, value| [key.to_s, value.to_s] }, T::Hash[String, String])
      end

      sig {
        override.params(
          force:   T::Boolean,
          adopt:   T::Boolean,
          command: T.class_of(SystemCommand),
          options: T.anything,
        ).void
      }
      def install_phase(force: false, adopt: false, command: SystemCommand, **options)
        if (content = @content)
          source.dirname.mkpath
          source.write(content)
        elsif (executable = @executable)
          args = @args.map { |arg| Shellwords.shellescape(arg) }
          source.write_env_script(executable, args, @env)
        end
        super
      end

      sig { override.returns(T::Array[T.anything]) }
      def to_args
        options = { target: @target_string }
        if (content = @content)
          options[:content] = content
        else
          options[:executable] = @executable
          options[:args] = @args if @args.present?
          options[:env] = @env if @env.present?
        end
        [@source_string, options]
      end
    end
  end
end
