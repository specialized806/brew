# typed: strict

class RSpec::Core::ExampleGroup
  include RSpec::SharedContext
  include RSpec::Matchers
  include RSpec::Mocks::ExampleMethods

  # `mktmpdir` is mixed into specs via `config.include(Test::Helper::MkTmpDir)`
  # in `test/spec_helper.rb`; declare it here so Sorbet can resolve it in typed
  # spec files.
  sig {
    type_parameters(:U)
      .params(
        prefix_suffix: T.nilable(T.any(String, T::Array[String])),
        block:         T.proc.params(path: Pathname).returns(T.type_parameter(:U)),
      ).returns(T.type_parameter(:U))
  }
  sig {
    params(
      prefix_suffix: T.nilable(T.any(String, T::Array[String])),
      block:         T.nilable(T.proc.params(path: Pathname).returns(Pathname)),
    ).returns(Pathname)
  }
  def mktmpdir(prefix_suffix = T.unsafe(nil), &block); end
end

# The rspec-mocks RBI defines `ExpectHost#expect(target)` with a required
# argument and no block, which conflicts with the block form `expect { ... }`
# required by matchers like `raise_error`, `output`, `change`, etc.
# Override it to match the rspec-expectations signature.
module RSpec::Mocks::ExampleMethods::ExpectHost
  sig { params(value: T.untyped, block: T.nilable(T.proc.void)).returns(T.untyped) }
  def expect(value = T.unsafe(nil), &block); end
end
