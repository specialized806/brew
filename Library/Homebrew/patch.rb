# typed: strict
# frozen_string_literal: true

require "embedded_patch"
require "data_patch"
require "external_patch"
require "string_patch"

# Helper module for creating patches.
module Patch
  sig {
    params(
      strip: T.any(Symbol, String),
      src:   T.nilable(T.any(Symbol, String)),
      block: T.nilable(T.proc.bind(Resource::Patch).void),
    ).returns(T.any(EmbeddedPatch, ExternalPatch))
  }
  def self.create(strip, src, &block)
    case strip
    when :DATA
      DATAPatch.new(:p1)
    when String
      StringPatch.new(:p1, strip)
    when Symbol
      case src
      when :DATA
        DATAPatch.new(strip)
      when String
        StringPatch.new(strip, src)
      else
        ExternalPatch.new(strip, &block)
      end
    end
  end
end
