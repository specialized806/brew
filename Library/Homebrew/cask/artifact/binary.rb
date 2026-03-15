# typed: strict
# frozen_string_literal: true

require "cask/artifact/symlinked"

module Cask
  module Artifact
    # Artifact corresponding to the `binary` stanza.
    class Binary < Symlinked
      sig { params(command: T.nilable(T.class_of(SystemCommand)), options: T.untyped).void }
      def link(command: nil, **options)
        super
        return if source.executable?

        if source.writable?
          FileUtils.chmod "+x", source
        else
          T.must(command).run!("chmod", args: ["+x", source], sudo: true)
        end
      end
    end
  end
end
