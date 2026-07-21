# typed: strict
# frozen_string_literal: true

require "extend/os/linux/sandbox/bubblewrap"

module OS
  module Linux
    module Sandbox
      extend T::Helpers

      requires_ancestor { ::Sandbox }

      # `TIOCSCTTY` from `<asm-generic/ioctls.h>`; Ruby does not expose it.
      TIOCSCTTY = 0x540E
      private_constant :TIOCSCTTY

      sig { returns(::PATH) }
      def self.bubblewrap_candidate_paths
        ::Sandbox::Bubblewrap.executable_candidate_paths
      end

      sig { returns(T.nilable(::Pathname)) }
      def self.bubblewrap_executable
        ::Sandbox::Bubblewrap.executable
      end

      sig { returns(::Pathname) }
      def self.bubblewrap_executable!
        ::Sandbox::Bubblewrap.executable!
      end

      sig { void }
      def allow_write_temp_and_cache
        allow_write_path "/tmp"
        allow_write_path "/var/tmp"
        allow_write_path HOMEBREW_TEMP
        allow_write_path HOMEBREW_CACHE
      end

      sig { void }
      def allow_cvs
        cvspass = ::Pathname.new("#{Dir.home(ENV.fetch("USER"))}/.cvspass")
        allow_write path: cvspass, type: :literal if cvspass.exist?
      end

      sig { void }
      def allow_fossil
        [".fossil", ".fossil-journal"].each do |file|
          fossil_file = ::Pathname.new("#{Dir.home(ENV.fetch("USER"))}/#{file}")
          allow_write path: fossil_file, type: :literal if fossil_file.exist?
        end
      end

      module ClassMethods
        extend T::Helpers

        requires_ancestor { T.class_of(::Sandbox) }

        sig { returns(String) }
        def executable_name
          ::Sandbox::Bubblewrap.executable_name
        end

        sig { params(candidate: ::Pathname).returns(T::Boolean) }
        def executable_usable?(candidate)
          ::Sandbox::Bubblewrap.executable_usable?(candidate)
        end

        sig { returns(T::Array[String]) }
        def system_bubblewrap_paths
          ::Sandbox::Bubblewrap.system_paths
        end

        sig { returns(::PATH) }
        def executable_candidate_paths
          ::Sandbox::Bubblewrap.executable_candidate_paths
        end

        sig { returns(::PATH) }
        def bubblewrap_candidate_paths
          executable_candidate_paths
        end

        sig { returns(T.nilable(::Pathname)) }
        def bubblewrap_executable
          ::Sandbox::Bubblewrap.executable
        end

        sig { returns(::Pathname) }
        def bubblewrap_executable!
          ::Sandbox::Bubblewrap.executable!
        end

        sig { params(install_from_tests: T::Boolean).void }
        def ensure_sandbox_installed!(install_from_tests: false)
          ::Sandbox::Bubblewrap.ensure_installed!(install_from_tests:)
        end

        sig { returns(T::Boolean) }
        def available?
          ::Sandbox::Bubblewrap.available?
        end

        # Bubblewrap reports this specific namespace error when an outer
        # Bubblewrap sandbox prevents Homebrew from creating another rootless
        # sandbox. The shared `avoid_nested_sandboxing?` only calls this once the
        # `$HOMEBREW_AVOID_NESTED_SANDBOXING` opt-in is set.
        sig { returns(T::Boolean) }
        def nested_sandbox?
          ::Sandbox::Bubblewrap.nested_sandbox?
        end

        sig { returns(Symbol) }
        def state
          ::Sandbox::Bubblewrap.state
        end

        sig { void }
        def reset_state!
          ::Sandbox::Bubblewrap.reset_state!
        end

        sig { returns(T::Array[String]) }
        def configuration_commands
          ::Sandbox::Bubblewrap.configuration_commands
        end

        sig { returns(T::Array[String]) }
        def configuration_command_messages
          ::Sandbox::Bubblewrap.configuration_command_messages
        end

        sig { void }
        def configure!
          ::Sandbox::Bubblewrap.configure!
        end

        sig { returns(T.nilable(String)) }
        def failure_reason
          ::Sandbox::Bubblewrap.failure_reason
        end

        sig { returns(T.nilable(String)) }
        def sandbox_install_command
          ::Sandbox::Bubblewrap.install_command
        end

        # `ioctl` request used to attach the sandboxed child to a controlling TTY.
        sig { returns(Integer) }
        def terminal_ioctl_request
          TIOCSCTTY
        end
      end

      sig { params(args: T.any(String, ::Pathname)).void }
      def run(*args)
        bubblewrap.run { super }
      end

      private

      sig { params(args: T::Array[T.any(String, ::Pathname)], tmpdir: String).returns(T::Array[T.any(String, ::Pathname)]) }
      def sandbox_command(args, tmpdir)
        bubblewrap.command(args, tmpdir)
      end

      sig { params(tmpdir: String).returns(T::Array[String]) }
      def bubblewrap_args(tmpdir)
        bubblewrap.arguments(tmpdir)
      end

      sig { returns(T::Hash[String, Symbol]) }
      def writable_paths
        bubblewrap.writable_paths
      end

      sig { returns(::Sandbox::Bubblewrap) }
      def bubblewrap
        @bubblewrap ||= T.let(::Sandbox::Bubblewrap.new(profile), T.nilable(::Sandbox::Bubblewrap))
      end
    end
  end
end

Sandbox.prepend(OS::Linux::Sandbox)
Sandbox.singleton_class.prepend(OS::Linux::Sandbox::ClassMethods)
