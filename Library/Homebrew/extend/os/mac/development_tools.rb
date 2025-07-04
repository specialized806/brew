# typed: strict
# frozen_string_literal: true

require "os/mac/xcode"

module OS
  module Mac
    module DevelopmentTools
      module ClassMethods
        extend T::Helpers

        requires_ancestor { ::DevelopmentTools }

        sig { params(tool: T.any(String, Symbol)).returns(T.nilable(Pathname)) }
        def locate(tool)
          @locate ||= T.let({}, T.nilable(T::Hash[T.any(String, Symbol), Pathname]))
          @locate.fetch(tool) do |key|
            @locate[key] = if (located_tool = super(tool))
              located_tool
            else
              path = Utils.popen_read("/usr/bin/xcrun", "-no-cache", "-find", tool, err: :close).chomp
              Pathname.new(path) if File.executable?(path)
            end
          end
        end

        # Checks if the user has any developer tools installed, either via Xcode
        # or the CLT. Convenient for guarding against formula builds when building
        # is impossible.
        sig { returns(T::Boolean) }
        def installed?
          MacOS::Xcode.installed? || MacOS::CLT.installed?
        end

        sig { returns(Symbol) }
        def default_compiler
          :clang
        end

        sig { returns(Version) }
        def ld64_version
          @ld64_version ||= T.let(begin
            json = Utils.popen_read("/usr/bin/ld", "-version_details")
            if $CHILD_STATUS.success?
              Version.parse(JSON.parse(json)["version"])
            else
              Version::NULL
            end
          end, T.nilable(Version))
        end

        sig { returns(T::Boolean) }
        def curl_handles_most_https_certificates?
          # The system Curl is too old for some modern HTTPS certificates on
          # older macOS versions.
          ENV["HOMEBREW_SYSTEM_CURL_TOO_OLD"].nil?
        end

        sig { returns(T::Boolean) }
        def subversion_handles_most_https_certificates?
          # The system Subversion is too old for some HTTPS certificates on
          # older macOS versions.
          MacOS.version >= :sierra
        end

        sig { returns(String) }
        def installation_instructions
          MacOS::CLT.installation_instructions
        end

        sig { returns(String) }
        def custom_installation_instructions
          <<~EOS
            Install GNU's GCC:
              brew install gcc
          EOS
        end

        sig { returns(T::Hash[String, T.nilable(String)]) }
        def build_system_info
          build_info = {
            "xcode"          => MacOS::Xcode.version.to_s.presence,
            "clt"            => MacOS::CLT.version.to_s.presence,
            "preferred_perl" => MacOS.preferred_perl_version,
          }
          super.merge build_info
        end
      end
    end
  end
end

DevelopmentTools.singleton_class.prepend(OS::Mac::DevelopmentTools::ClassMethods)
