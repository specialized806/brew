# typed: strict
# frozen_string_literal: true

# A requirement on Linux.
class LinuxRequirement < Requirement
  # Sorbet type members are mutable by design and cannot be frozen.
  # rubocop:disable Style/MutableConstant
  Cache = type_template { { fixed: T::Hash[String, T.untyped] } }
  # rubocop:enable Style/MutableConstant

  fatal true

  satisfy(build_env: false) { OS.linux? }

  sig { returns(String) }
  def display_s
    "Linux"
  end

  sig { returns(String) }
  def message
    "Linux is required for this software."
  end
end
