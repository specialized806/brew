# typed: strict
# frozen_string_literal: true

require "cask/macos"

module OS
  module Mac
    module Cask
      module Installer
        extend T::Helpers

        requires_ancestor { ::Cask::Installer }

        sig { params(predecessor: T.nilable(::Cask::Cask)).void }
        def install_artifacts(predecessor: nil)
          # Resolve and memoize the system languages before any artifact work:
          # resolving them lazily later (e.g. while serializing the cask config)
          # would fork (`Utils.popen`) after this process has already used
          # fork-hostile frameworks such as Security.framework for signing
          # checks.
          # https://github.com/Homebrew/brew/issues/23606
          MacOS.languages

          super
        end
      end
    end
  end
end

Cask::Installer.prepend(OS::Mac::Cask::Installer)
