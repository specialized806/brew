# typed: strict
# frozen_string_literal: true

require "rubocops/shared/url_helper"

module RuboCop
  module Cop
    module Cask
      # This cop checks that a cask's `url` stanza is formatted correctly.
      #
      # ### Example
      #
      # ```ruby
      # # bad
      # url "https://example.com/download/foo.dmg",
      #     verified: "https://example.com/download"
      #
      # # good
      # url "https://example.com/download/foo.dmg",
      #     verified: "example.com/download/"
      # ```
      class Url < Base
        extend AutoCorrector
        include OnUrlStanza
        include UrlHelper

        sig { params(stanza: RuboCop::Cask::AST::Stanza).void }
        def on_url_stanza(stanza)
          if stanza.stanza_node.block_type?
            if cask_tap == "homebrew-cask"
              add_offense(stanza.stanza_node, message: 'Do not use `url "..." do` blocks in Homebrew/homebrew-cask.')
            end
            return
          end

          stanza_node = T.cast(stanza.stanza_node, RuboCop::AST::SendNode)
          url_stanza = stanza_node.first_argument
          hash_node = stanza_node.last_argument

          if url_stanza.nil? || url_stanza.hash_type?
            add_offense(stanza_node.source_range, message: "The `url` stanza requires a URL argument.")
            return
          end

          audit_url(:cask, [stanza_node], [], livecheck_urls: [])

          if cask_tap == "homebrew-cask" && !url_stanza.type?(:str, :dstr)
            add_offense(url_stanza.source_range, message: "Casks in homebrew/cask should use string literal URLs.")
          end

          # Check for http:// URLs in homebrew-cask (skip deprecated/disabled casks)
          # TODO: Remove the deprecated/disabled check after Homebrew/cask has no more
          # deprecated/disabled casks using http:// URLs
          deprecated_or_disabled = toplevel_stanzas.any? { |s| [:deprecate!, :disable!].include?(s.stanza_name) }
          if cask_tap == "homebrew-cask" && !deprecated_or_disabled && url_stanza.source.match?(%r{^"http://})
            add_offense(
              stanza_node.source_range,
              message: "Casks in homebrew/cask should not use http:// URLs",
            ) do |corrector|
              corrector.replace(stanza_node.source_range, stanza_node.source.sub("http://", "https://"))
            end
          end

          return unless hash_node.hash_type?

          # TODO: also enforce that each keyword parameter after the first
          #       starts on its own line (e.g. `verified:` and `header:`
          #       should not share a line).
          if hash_node.first_line <= url_stanza.last_line || hash_node.loc.column <= stanza_node.loc.column
            add_offense(
              stanza_node.source_range,
              message: "Keyword URL parameter should be on a new indented line.",
            ) do |corrector|
              corrector.replace(
                range_between(url_stanza.source_range.end_pos, hash_node.source_range.begin_pos),
                ",\n#{" " * url_stanza.loc.column}",
              )
            end
          end

          hash_node.each_pair do |key_node, value_node|
            next if key_node.source != "verified"
            next unless value_node.str_type?

            if value_node.source.start_with?(%r{^"https?://})
              add_offense(
                value_node.source_range,
                message: "Verified URL parameter value should not contain a URL scheme.",
              ) do |corrector|
                corrector.replace(value_node.source_range, value_node.source.gsub(%r{^"https?://}, "\""))
              end
            end

            # Skip if the URL and the verified value are the same.
            next if value_node.source == url_stanza.source.gsub(%r{^"https?://}, "\"")
            # Skip if the URL has two path components, e.g. `https://github.com/google/fonts.git`.
            next if url_stanza.source.gsub(%r{^"https?://}, "\"").count("/") == 2
            # Skip if the verified value ends with a slash.
            next if value_node.str_content.end_with?("/")

            add_offense(
              value_node.source_range,
              message: "Verified URL parameter value should end with a /.",
            ) do |corrector|
              corrector.replace(value_node.source_range, value_node.source.gsub(/"$/, "/\""))
            end
          end
        end
      end
    end
  end
end
