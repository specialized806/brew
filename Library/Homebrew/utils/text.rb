# typed: strict
# frozen_string_literal: true

module Utils
  module Text
    module_function

    sig {
      type_parameters(:Elem).params(
        values:      T::Array[T.type_parameter(:Elem)],
        conjunction: String,
      ).returns(String)
    }
    def to_sentence(values, conjunction: "and")
      case values.length
      when 0
        +""
      when 1
        +T.unsafe(values[0]).to_s
      when 2
        "#{values[0]} #{conjunction} #{values[1]}"
      else
        "#{T.must(values[0...-1]).join(", ")} #{conjunction} #{values[-1]}"
      end
    end
  end
end
