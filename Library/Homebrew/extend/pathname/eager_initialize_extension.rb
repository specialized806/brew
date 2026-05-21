# typed: strict
# frozen_string_literal: true

module EagerInitializeExtension
  extend T::Helpers

  requires_ancestor { Pathname }

  sig { params(args: T.untyped).void }
  def initialize(*args)
    @magic_number = T.let(nil, T.nilable(String))
    @file_type = T.let(nil, T.nilable(String))
    @zipinfo = T.let(nil, T.nilable(T::Array[String]))
    @which_install_info = T.let(nil, T.nilable(String))
    @disk_usage = T.let(nil, T.nilable(Integer))
    @file_count = T.let(nil, T.nilable(Integer))
    super
  end
end
