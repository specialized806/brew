# typed: strict
# frozen_string_literal: true

module Utils
  module Data
    module_function

    sig {
      type_parameters(:Key, :Value).params(
        hash:       T::Hash[T.type_parameter(:Key), T.type_parameter(:Value)],
        valid_keys: T.any(T.type_parameter(:Key), T::Array[T.type_parameter(:Key)]),
      ).void
    }
    def assert_valid_keys(hash, *valid_keys)
      valid_keys.flatten!
      hash.each_key do |key|
        next if valid_keys.include?(key)

        Kernel.raise ArgumentError,
                     "Unknown key: #{T.unsafe(key).inspect}. " \
                     "Valid keys are: #{valid_keys.map { |valid_key| T.unsafe(valid_key).inspect }.join(", ")}"
      end
    end
  end
end
