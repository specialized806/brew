# typed: strict
# frozen_string_literal: true

require "bundle/extensions/extension"

module Homebrew
  module Bundle
    class Npm < Extension
      PACKAGE_TYPE = :npm
      PACKAGE_TYPE_NAME = "npm Package"
      BANNER_NAME = "npm packages"

      class << self
        sig { override.void }
        def reset!
          @packages = T.let(nil, T.nilable(T::Array[String]))
          @installed_packages = T.let(nil, T.nilable(T::Array[String]))
        end

        sig { override.returns(String) }
        def package_manager_name
          "node"
        end

        sig { override.returns(T.nilable(Pathname)) }
        def package_manager_executable
          which("npm", ORIGINAL_PATHS)
        end

        sig { override.returns(T::Array[String]) }
        def packages
          packages = @packages
          return packages if packages

          @packages = if (npm = package_manager_executable) &&
                         (!npm.to_s.start_with?("/") || npm.exist?)
            parse_package_list(`#{npm} list -g --depth=0 --json 2>/dev/null`)
          end
          return [] if @packages.nil?

          @packages
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

          npm = package_manager_executable!

          Bundle.system(npm.to_s, "install", "-g", name, verbose:)
        end

        sig { override.returns(T::Array[String]) }
        def installed_packages
          installed_packages = @installed_packages
          return installed_packages if installed_packages

          @installed_packages = packages.dup
        end

        sig { override.returns(String) }
        def cleanup_heading
          "npm packages"
        end

        sig { params(entries: T::Array[Object]).returns(T::Array[String]) }
        def cleanup_items(entries)
          return [].freeze unless package_manager_installed?

          kept_packages = entries.filter_map do |entry|
            entry = T.cast(entry, Dsl::Entry)
            entry.name if entry.type == type
          end

          return [].freeze if kept_packages.empty?

          packages - kept_packages
        end

        sig { params(items: T::Array[String]).void }
        def cleanup!(items)
          npm = package_manager_executable
          return if npm.nil?

          items.each do |name|
            Bundle.system(npm.to_s, "uninstall", "-g", name, verbose: false)
          end
          puts "Uninstalled #{items.size} npm package#{"s" if items.size != 1}"
        end

        sig { params(output: String).returns(T::Array[String]) }
        def parse_package_list(output)
          return [] if output.blank?

          json = JSON.parse(output)
          deps = json.fetch("dependencies", {})
          deps.keys.reject { |name| name == "npm" }
        rescue JSON::ParserError
          []
        end
        private :parse_package_list
      end
    end
  end
end
