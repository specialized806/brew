# typed: strict
# frozen_string_literal: true

require "cask/cask_loader"
module OS
  module Linux
    module Bundle
      module Skipper
        module ClassMethods
          sig { params(entry: Homebrew::Bundle::Dsl::Entry).returns(T::Boolean) }
          def requires_macos?(entry)
            case entry.type
            when :mas
              true
            when :cask
              !::Cask::CaskLoader.load(entry.name).supports_linux?
            else
              false
            end
          rescue ::Cask::CaskError
            true
          end

          sig { params(entry: Homebrew::Bundle::Dsl::Entry, silent: T::Boolean).returns(T::Boolean) }
          def skip?(entry, silent: false)
            return super unless requires_macos?(entry)

            $stdout.puts Formatter.warning("Skipping #{entry.type} #{entry.name} (requires macOS)") unless silent
            true
          end
        end
      end
    end
  end
end

Homebrew::Bundle::Skipper.singleton_class.prepend(OS::Linux::Bundle::Skipper::ClassMethods)
