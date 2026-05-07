# typed: strict
# frozen_string_literal: true

require "embedded_patch"
require "data_patch"
require "external_patch"
require "string_patch"
require "local_patch"

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
        external_patch = ExternalPatch.new(strip, &block)
        resource = external_patch.resource
        if (file = resource.file)
          raise ArgumentError, "Patch cannot have both `file` and `url`." if resource.url.present?
          raise ArgumentError, "Patch cannot use `sha256` with `file`." if resource.checksum
          raise ArgumentError, "Patch cannot use `directory` with `file`." if resource.directory.present?
          raise ArgumentError, "Patch cannot use `apply` with `file`." if resource.patch_files.present?

          LocalPatch.new(strip, file)
        else
          external_patch
        end
      end
    end
  end
end
