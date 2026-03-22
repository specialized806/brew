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
        end

        sig { override.returns(String) }
        def package_manager_name
          "krew"
        end

        sig { override.returns(T.nilable(Pathname)) }
        def package_manager_executable
          Bundle.which_krew
        end

        sig { override.returns(T::Boolean) }
        def package_manager_installed?
          Bundle.krew_installed?
        end

        sig { override.returns(T::Array[String]) }
        def packages
          packages = @packages
          return packages if packages

          @packages = if Bundle.krew_installed?
            kubectl = Bundle.which_krew
            return [] if kubectl.nil?

            env = { "PATH" => "#{kubectl.dirname}:#{ENV.fetch("PATH")}" }
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
            next if line.start_with?("PLUGIN")

            # kubectl krew list output format: "PLUGIN  VERSION"
            name = line.split(/\s+/).first
            name if name && !name.empty?
          end.uniq
        end
        private :parse_plugin_list
      end
    end

    # TODO: Remove these compatibility aliases once bundle callers and tests
    # stop requiring separate krew dumper/installer/checker constants.
    KrewDumper = Krew
    KrewInstaller = Krew

    module Checker
      # TODO: Remove this compatibility alias once bundle callers and tests stop
      # requiring a separate krew checker constant.
      KrewChecker = Homebrew::Bundle::Krew
    end
  end
end
