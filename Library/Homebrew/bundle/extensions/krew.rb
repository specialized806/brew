# typed: strict
# frozen_string_literal: true

require "bundle/extensions/extension"

module Homebrew
  module Bundle
    class Krew < Extension
      PACKAGE_TYPE = :krew
      PACKAGE_TYPE_NAME = "Krew Plugin"
      BANNER_NAME = "Krew plugins"

      class << self
        sig { override.void }
        def reset!
          @packages = T.let(nil, T.nilable(T::Array[String]))
          @installed_packages = T.let(nil, T.nilable(T::Array[String]))
          @package_manager_executable = T.let(nil, T.nilable(Pathname))
          @krew_installed = T.let(nil, T.nilable(T::Boolean))
        end

        sig { override.returns(T.nilable(Pathname)) }
        def package_manager_executable
          @package_manager_executable ||= T.let(which("kubectl", ORIGINAL_PATHS), T.nilable(Pathname))
        end

        sig { override.returns(T::Boolean) }
        def package_manager_installed?
          return @krew_installed unless @krew_installed.nil?

          kubectl = package_manager_executable
          result = if kubectl.present?
            env = { "PATH" => "#{kubectl.dirname}:#{ORIGINAL_PATHS.join(":")}" }
            Kernel.system(env, kubectl.to_s, "krew", "version", out: File::NULL, err: File::NULL) == true
          else
            false
          end
          @krew_installed = T.let(result, T.nilable(T::Boolean))
          result
        end

        sig { override.returns(T::Array[String]) }
        def packages
          packages = @packages
          return packages if packages

          kubectl = package_manager_executable
          @packages = if package_manager_installed? && kubectl
            env = { "PATH" => "#{kubectl.dirname}:#{ORIGINAL_PATHS.join(":")}" }
            output = with_env(env) { `#{kubectl} krew list 2>/dev/null` }
            parse_plugin_list(output)
          else
            []
          end
        end

        sig {
          override.params(
            name:    String,
            with:    T.nilable(T::Array[String]),
            verbose: T::Boolean,
          ).returns(T::Boolean)
        }
        def install_package!(name, with: nil, verbose: false)
          _ = with

          kubectl = package_manager_executable
          return false if kubectl.nil?

          env = { "PATH" => "#{kubectl.dirname}:#{ENV.fetch("PATH")}" }
          with_env(env) do
            Bundle.system(kubectl.to_s, "krew", "install", name, verbose:)
          end
        end

        sig { override.returns(T::Array[String]) }
        def installed_packages
          installed_packages = @installed_packages
          return installed_packages if installed_packages

          @installed_packages = packages.dup
        end

        sig { params(output: String).returns(T::Array[String]) }
        def parse_plugin_list(output)
          output.lines.filter_map do |line|
            line = line.strip
            next if line.empty?

            name = line.split(/\s+/).first
            name.presence
          end.uniq
        end
        private :parse_plugin_list
      end
    end
  end
end
