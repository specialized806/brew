# typed: strict
# frozen_string_literal: true

module Homebrew
  module Vulns
    # Strict Semantic Versioning 2.0 comparison, as required for evaluating
    # OSV `SEMVER` ranges. See https://semver.org/#spec-item-11.
    #
    # This is intentionally separate from `::Version` because Homebrew's
    # version ordering is not SemVer-compliant for prerelease identifiers or
    # build metadata.
    module Semver
      SEMVER_REGEX = /\A(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?\z/
      private_constant :SEMVER_REGEX

      NUMERIC_IDENTIFIER = /\A\d+\z/
      private_constant :NUMERIC_IDENTIFIER

      # Compare two version strings according to SemVer 2.0 precedence rules.
      # Returns -1, 0 or 1 in the usual `<=>` sense, or `nil` if either side
      # cannot be parsed as a semantic version.
      sig { params(left: String, right: String).returns(T.nilable(Integer)) }
      def self.compare(left, right)
        a = parse(left)
        b = parse(right)
        return if a.nil? || b.nil?

        core = a.fetch(:core) <=> b.fetch(:core)
        return core unless core.zero?

        compare_prerelease(a.fetch(:prerelease), b.fetch(:prerelease))
      end

      sig { params(version: String).returns(T.nilable({ core: [Integer, Integer, Integer], prerelease: T::Array[String] })) }
      private_class_method def self.parse(version)
        match = version.strip.delete_prefix("v").delete_prefix("V").match(SEMVER_REGEX)
        return if match.nil?

        {
          core:       [match[1].to_i, match[2].to_i, match[3].to_i],
          prerelease: match[4]&.split(".") || [],
        }
      end

      sig { params(left: T::Array[String], right: T::Array[String]).returns(Integer) }
      private_class_method def self.compare_prerelease(left, right)
        # A version without a prerelease has higher precedence than one with.
        return 0 if left.empty? && right.empty?
        return 1 if left.empty?
        return -1 if right.empty?

        left.zip(right) do |lhs, rhs|
          # A larger set of fields has higher precedence if all preceding
          # identifiers are equal (spec 11.4.4).
          return 1 if rhs.nil?

          cmp = compare_identifier(lhs, rhs)
          return cmp unless cmp.zero?
        end
        (left.length == right.length) ? 0 : -1
      end

      sig { params(lhs: String, rhs: String).returns(Integer) }
      private_class_method def self.compare_identifier(lhs, rhs)
        lhs_numeric = lhs.match?(NUMERIC_IDENTIFIER)
        rhs_numeric = rhs.match?(NUMERIC_IDENTIFIER)

        # Numeric identifiers always have lower precedence than alphanumeric
        # identifiers (spec 11.4.3).
        return -1 if lhs_numeric && !rhs_numeric
        return 1 if !lhs_numeric && rhs_numeric

        if lhs_numeric
          lhs.to_i <=> rhs.to_i
        else
          T.must(lhs <=> rhs)
        end
      end
    end
  end
end
