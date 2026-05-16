# typed: strict
# frozen_string_literal: true

require "fileutils"
require "env_config"

module OS
  module Linux
    module Sandbox
      extend T::Helpers

      requires_ancestor { ::Sandbox }

      BUBBLEWRAP = "bwrap"
      SYSTEM_BUBBLEWRAP_PATHS = T.let(%w[
        /usr/bin
        /bin
      ].freeze, T::Array[String])
      # `TIOCSCTTY` from `<asm-generic/ioctls.h>`; Ruby does not expose it.
      TIOCSCTTY = 0x540E
      READ_ONLY_PATHS = T.let(%w[
        /bin
        /etc
        /lib
        /lib64
        /opt
        /run
        /sbin
        /sys
        /usr
      ].freeze, T::Array[String])
      private_constant :BUBBLEWRAP, :SYSTEM_BUBBLEWRAP_PATHS, :TIOCSCTTY, :READ_ONLY_PATHS

      sig { returns(::PATH) }
      def self.bubblewrap_candidate_paths
        ::Sandbox.executable_candidate_paths
      end

      sig { returns(T.nilable(::Pathname)) }
      def self.bubblewrap_executable
        ::Sandbox.executable
      end

      sig { returns(::Pathname) }
      def self.bubblewrap_executable!
        bubblewrap_executable || raise("Bubblewrap is required to use the Linux sandbox.")
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
          BUBBLEWRAP
        end

        sig { params(candidate: ::Pathname).returns(T::Boolean) }
        def executable_usable?(candidate)
          !File.stat(candidate).setuid?
        end

        sig { returns(T::Array[String]) }
        def system_bubblewrap_paths
          SYSTEM_BUBBLEWRAP_PATHS
        end

        sig { returns(::PATH) }
        def executable_candidate_paths
          PATH.new(system_bubblewrap_paths, super)
        end

        sig { returns(::PATH) }
        def bubblewrap_candidate_paths
          executable_candidate_paths
        end

        sig { returns(T.nilable(::Pathname)) }
        def bubblewrap_executable
          executable
        end

        sig { returns(::Pathname) }
        def bubblewrap_executable!
          bubblewrap_executable || raise("Bubblewrap is required to use the Linux sandbox.")
        end

        sig { void }
        def ensure_sandbox_installed!
          return unless Homebrew::EnvConfig.sandbox_linux?
          # Never trigger a real install during `brew tests`.
          return if ENV["HOMEBREW_TESTS"]
          return if ENV["HOMEBREW_INSTALLING_BUBBLEWRAP"]
          return if bubblewrap_executable

          require "tap"
          return unless ::CoreTap.instance.installed?

          require "exceptions"
          require "formula"
          with_env(HOMEBREW_INSTALLING_BUBBLEWRAP: "1") do
            ::Formula["bubblewrap"].ensure_installed!(reason: "Linux sandboxing")
          end
        rescue ::FormulaUnavailableError
          nil
        end

        sig { returns(T::Boolean) }
        def available?
          return false unless Homebrew::EnvConfig.sandbox_linux?
          return false unless (bubblewrap = executable)

          system(
            bubblewrap.to_s,
            "--unshare-user",
            "--unshare-ipc",
            "--unshare-pid",
            "--unshare-uts",
            "--unshare-cgroup-try",
            "--ro-bind", "/", "/",
            "--proc", "/proc",
            "--dev", "/dev",
            "true",
            out: File::NULL,
            err: File::NULL
          ) == true
        end

        # `ioctl` request used to attach the sandboxed child to a controlling TTY.
        sig { returns(Integer) }
        def terminal_ioctl_request
          TIOCSCTTY
        end
      end

      sig { params(args: T.any(String, ::Pathname)).void }
      def run(*args)
        @prepared_writable_paths = T.let([], T.nilable(T::Array[::Pathname]))
        old_report_on_exception = T.let(Thread.report_on_exception, T.nilable(T::Boolean))
        Thread.report_on_exception = false
        super
      ensure
        Thread.report_on_exception = old_report_on_exception unless old_report_on_exception.nil?
        @prepared_writable_paths&.reverse_each do |path|
          path.rmdir if path.directory?
        rescue Errno::ENOENT, Errno::ENOTEMPTY
          nil
        end
        @prepared_writable_paths = nil
      end

      private

      sig { params(args: T::Array[T.any(String, ::Pathname)], tmpdir: String).returns(T::Array[T.any(String, ::Pathname)]) }
      def sandbox_command(args, tmpdir)
        [::Sandbox.executable!, *bubblewrap_args(tmpdir), "--", *args]
      end

      sig { params(tmpdir: String).returns(T::Array[String]) }
      def bubblewrap_args(tmpdir)
        args = T.let([
          "--unshare-user",
          "--unshare-ipc",
          "--unshare-pid",
          "--unshare-uts",
          "--unshare-cgroup-try",
          "--die-with-parent",
          "--new-session",
          "--dev", "/dev",
          "--proc", "/proc",
          "--dir", "/var"
        ], T::Array[String])
        args << "--unshare-net" if deny_all_network?

        ::Pathname.new(tmpdir).ascend.to_a.reverse_each do |path|
          next if path.root?

          args += ["--dir", path.to_s]
        end

        read_only_mounts = read_only_paths
        read_only_parent_paths = read_only_mounts.flat_map do |path|
          ::Pathname.new(path).ascend.to_a.reverse.filter_map do |parent|
            parent.to_s if !parent.root? && parent.to_s != path
          end
        end.uniq
        read_only_parent_paths.each do |path|
          args += ["--dir", path]
        end

        read_only_mounts.each do |path|
          args += ["--ro-bind", path, path]
        end

        writable_paths.each do |path, type|
          prepare_writable_path(path, type)
          args += ["--bind", path, path]
        end

        denied_write_paths.each do |path|
          next unless File.exist?(path)

          args += ["--ro-bind", path, path]
        end

        args += ["--bind", tmpdir, tmpdir, "--chdir", tmpdir]

        args
      end

      sig { returns(T::Boolean) }
      def deny_all_network?
        profile.rules.any? do |rule|
          !rule.allow && rule.operation == "network*" && rule.filter.nil?
        end
      end

      sig { returns(T::Array[String]) }
      def read_only_paths
        (READ_ONLY_PATHS + [HOMEBREW_PREFIX.to_s, HOMEBREW_REPOSITORY.to_s, HOMEBREW_LIBRARY_PATH.to_s] +
          profile.rules.filter_map do |rule|
            next if !rule.allow || !rule.operation.start_with?("file-read")
            next unless (filter = rule.filter)

            case filter.type
            when :literal, :subpath
              filter.path
            when :regex
              raise ArgumentError, "Linux sandbox does not support regex path filters: #{filter.path}"
            else
              raise ArgumentError, "Invalid path filter type: #{filter.type}"
            end
          end)
          .select { |path| File.exist?(path) }
          .uniq
      end

      sig { returns(T::Hash[String, Symbol]) }
      def writable_paths
        profile.rules.each_with_object({}) do |rule, paths|
          next if !rule.allow || !rule.operation.start_with?("file-write")
          next unless (filter = rule.filter)

          case filter.type
          when :literal, :subpath
            paths[filter.path] ||= filter.type
          when :regex
            raise ArgumentError, "Linux sandbox does not support regex path filters: #{filter.path}"
          else
            raise ArgumentError, "Invalid path filter type: #{filter.type}"
          end
        end
      end

      sig { returns(T::Array[String]) }
      def denied_write_paths
        profile.rules.filter_map do |rule|
          next if rule.allow || !rule.operation.start_with?("file-write")

          filter = rule.filter
          filter.path if filter && [:literal, :subpath].include?(filter.type)
        end.uniq
      end

      sig { params(path: String, type: Symbol).void }
      def prepare_writable_path(path, type)
        pathname = ::Pathname.new(path)
        return if pathname.exist?

        if type == :literal
          FileUtils.mkdir_p(pathname.dirname)
          FileUtils.touch(pathname)
        else
          FileUtils.mkdir_p(pathname)
          @prepared_writable_paths&.<< pathname
        end
      end
    end
  end
end

Sandbox.prepend(OS::Linux::Sandbox)
Sandbox.singleton_class.prepend(OS::Linux::Sandbox::ClassMethods)
