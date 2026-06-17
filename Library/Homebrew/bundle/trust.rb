# typed: strict
# frozen_string_literal: true

require "bundle/dsl"
require "utils"

module Homebrew
  module Bundle
    # Converts Brewfile `trusted` options into trust-store entries.
    module Trust
      TRUSTED_ITEM_KEYS = T.let({
        formula: [:formula, :formulae],
        cask:    [:cask, :casks],
        command: [:command, :commands],
      }.freeze, T::Hash[Symbol, T::Array[Symbol]])
      private_constant :TRUSTED_ITEM_KEYS

      sig { params(entries: T::Array[Homebrew::Bundle::Dsl::Entry]).returns(T::Array[[Symbol, String]]) }
      def self.entries(entries)
        entries.flat_map do |entry|
          trusted = entry.options[:trusted]
          full_name = T.cast(entry.options.fetch(:full_name, entry.name), String)

          entry_type = entry.type

          case entry_type
          when :tap
            next [] if trusted.blank?

            clone_target = entry.options[:clone_target].presence
            tap_reference = if clone_target
              require "tap"
              ::Tap.remote_to_reference(clone_target.to_s) || clone_target.to_s
            else
              entry.name
            end
            next [[:tap, tap_reference]] if trusted == true
            next [] unless trusted.is_a?(Hash)

            unsupported_keys = trusted.keys - TRUSTED_ITEM_KEYS.values.flatten
            raise UsageError, "Unsupported trusted keys: #{unsupported_keys.join(", ")}" if unsupported_keys.present?

            TRUSTED_ITEM_KEYS.flat_map do |type, keys|
              keys.flat_map do |key|
                Array(trusted[key]).filter_map do |item|
                  item_name = case item
                  when String, Symbol, Integer
                    Utils.name_from_full_name(item.to_s)
                  end
                  next if item_name.blank?

                  [type, "#{tap_reference}/#{item_name}"]
                end
              end
            end
          when :brew, :cask
            # Only fully-qualified names map to a tap, so unqualified names
            # cannot be meaningfully trusted.
            next [] if trusted != true || !Utils.full_name?(full_name)

            type = (entry_type == :brew) ? :formula : :cask
            [[type, full_name]]
          else
            []
          end
        end.uniq
      end
    end
  end
end
