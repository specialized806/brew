# typed: strict
# frozen_string_literal: true

module OS
  module Linux
    module Cask
      module Caskroom
        module ClassMethods
          # Unlike macOS (which uses the shared `admin` group for multi-admin support),
          # Homebrew on Linux is conventionally a single-user install, so it is OK to use
          # the current user's primary group as the group of the `Caskroom` directory.
          # This also avoids a `sudo` prompt to `chgrp` the directory after creation.
          sig { returns(String) }
          def expected_caskroom_group
            Etc.getgrgid(Process.egid)&.name || "root"
          end
        end
      end
    end
  end
end

Cask::Caskroom.singleton_class.prepend(OS::Linux::Cask::Caskroom::ClassMethods)
