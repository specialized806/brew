# typed: strict
# frozen_string_literal: true

require "cask/artifact/moved"

module Cask
  module Artifact
    # Artifact corresponding to the `mdimporter` stanza.
    class Mdimporter < Moved
      sig { override.returns(String) }
      def self.english_name
        "Spotlight metadata importer"
      end

      sig { params(options: T.untyped).void }
      def install_phase(**options)
        super
        reload_spotlight(**options)
      end

      private

      sig { params(command: T.nilable(T.class_of(SystemCommand)), _options: T.untyped).void }
      def reload_spotlight(command: nil, **_options)
        T.must(command).run!("/usr/bin/mdimport", args: ["-r", target])
      end
    end
  end
end
