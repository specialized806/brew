# typed: strict
# frozen_string_literal: true

require "yaml"

module Homebrew
  module Vulns
    # Reviewed, candidate-specific corrections for advisory matching. These are
    # intentionally keyed by formula and upstream advisory identifier so a bad
    # upstream range cannot silently change unrelated matches.
    class AdvisoryOverrides
      class Error < RuntimeError; end

      class Entry < T::Struct
        const :state, T.nilable(Symbol)
        const :fixed_in, T.nilable(String)
        const :fixed_in_overridden, T::Boolean
      end

      VALID_STATES = [:affected, :fixed, :not_applicable].freeze
      private_constant :VALID_STATES

      sig { params(path: Pathname).returns(AdvisoryOverrides) }
      def self.from_file(path)
        new(YAML.safe_load(path.read, permitted_classes: [], permitted_symbols: [], aliases: false))
      rescue Psych::Exception => e
        raise Error, "Failed to parse advisory overrides at #{path}: #{e.message}"
      end

      sig { params(data: T.untyped).void }
      def initialize(data)
        @skipped_formulae = T.let({}, T::Hash[String, T::Boolean])
        @advisories = T.let({}, T::Hash[String, T::Hash[String, Entry]])

        root = hash(data, "top level")
        root.each do |formula_name, raw_formula|
          raise Error, "Formula names must be strings" unless formula_name.is_a?(String)

          formula = hash(raw_formula, formula_name)
          reject_unknown_keys(formula, %w[skip advisories], formula_name)

          skip = formula.fetch("skip", false)
          raise Error, "#{formula_name}.skip must be true or false" unless [true, false].include?(skip)

          @skipped_formulae[formula_name] = true if skip
          next unless formula.key?("advisories")

          raw_advisories = hash(formula.fetch("advisories"), "#{formula_name}.advisories")
          parsed = T.let({}, T::Hash[String, Entry])
          raw_advisories.each do |identifier, raw_entry|
            raise Error, "#{formula_name} advisory identifiers must be strings" unless identifier.is_a?(String)

            entry = hash(raw_entry, "#{formula_name}.advisories.#{identifier}")
            reject_unknown_keys(entry, %w[range_state upstream_fixed_in],
                                "#{formula_name}.advisories.#{identifier}")

            state = T.let(nil, T.nilable(Symbol))
            if entry.key?("range_state")
              raw_state = entry.fetch("range_state")
              state = raw_state.to_sym if raw_state.is_a?(String)
              if state.nil? || VALID_STATES.exclude?(state)
                raise Error, "#{formula_name}.advisories.#{identifier}.range_state must be " \
                             "affected, fixed, or not_applicable"
              end
            end

            fixed_in_overridden = entry.key?("upstream_fixed_in")
            fixed_in = entry["upstream_fixed_in"]
            if !fixed_in.nil? && !fixed_in.is_a?(String)
              raise Error, "#{formula_name}.advisories.#{identifier}.upstream_fixed_in must be a string or null"
            end
            if state.nil? && !fixed_in_overridden
              raise Error, "#{formula_name}.advisories.#{identifier} must override at least one field"
            end

            parsed[identifier] = Entry.new(state:, fixed_in:, fixed_in_overridden:)
          end
          @advisories[formula_name] = parsed.freeze
        end
        @skipped_formulae.freeze
        @advisories.freeze
      end

      sig { params(formula_name: String).returns(T::Boolean) }
      def skip_formula?(formula_name)
        @skipped_formulae.key?(formula_name)
      end

      sig { params(formula_name: String, identifiers: T::Array[String]).returns(T.nilable(Entry)) }
      def advisory_override(formula_name, identifiers)
        formula = @advisories[formula_name]
        return unless formula

        identifiers.each do |identifier|
          override = formula[identifier]
          return override if override
        end
        nil
      end

      private

      sig { params(value: T.untyped, location: String).returns(T::Hash[T.untyped, T.untyped]) }
      def hash(value, location)
        return value if value.is_a?(Hash)

        raise Error, "#{location} must be a mapping"
      end

      sig {
        params(value: T::Hash[T.untyped, T.untyped], allowed: T::Array[String], location: String).void
      }
      def reject_unknown_keys(value, allowed, location)
        unknown = value.keys - allowed
        return if unknown.empty?

        raise Error, "#{location} has unknown key(s): #{unknown.join(", ")}"
      end
    end
  end
end
