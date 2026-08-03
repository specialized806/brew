# typed: strict
# frozen_string_literal: true

module UnpackStrategy
  class Dmg
    sig { returns(T::Boolean) }
    def self.diskutil_image?
      MacOS.version >= :sonoma
    end
  end
end
