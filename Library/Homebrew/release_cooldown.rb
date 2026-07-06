# typed: strict
# frozen_string_literal: true

module Homebrew
  RELEASE_COOLDOWN_DAYS = 1
  RELEASE_COOLDOWN_SECONDS = T.let(RELEASE_COOLDOWN_DAYS * 24 * 60 * 60, Integer)
end
