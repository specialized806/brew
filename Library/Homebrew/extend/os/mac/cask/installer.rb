# typed: strict
# frozen_string_literal: true

module OS
  module Mac
    module Cask
      module Installer
        extend T::Helpers

        requires_ancestor { ::Cask::Installer }

        sig { void }
        def check_stanza_os_requirements
          return if !cask.depends_on.requires_linux? && cask.artifacts_supported_on_os?(:macos)

          raise ::Cask::CaskError, "#{cask}: This cask requires Linux."
        end
      end
    end
  end
end

Cask::Installer.prepend(OS::Mac::Cask::Installer)
