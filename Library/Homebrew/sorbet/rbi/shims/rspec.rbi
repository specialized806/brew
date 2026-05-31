# typed: strict

class RSpec::Core::ExampleGroup
  include CopHelper
  include RSpec::SharedContext
  include RSpec::Matchers
  include RSpec::Mocks::ExampleMethods
  include RuboCop::RSpec::ExpectOffense

  # These methods are added to specs in
  # `test/support/helper/spec/shared_context/integration_test.rb`; declare them
  # here so Sorbet can resolve them in typed spec files.
  sig { params(args: T.untyped).returns(Process::Status) }
  def brew(*args); end
  sig { params(args: T.untyped).returns(Process::Status) }
  def brew_sh(*args); end
  sig { params(name: Formula).returns(Pathname) }
  def setup_test_formula(name); end
  sig { returns(Pathname) }
  def setup_test_tap; end
  sig { params(name: String).returns(Pathname) }
  def install_test_formula(name); end
  sig { params(name: String).returns(Pathname) }
  def uninstall_test_formula(name); end

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

# RuboCop cop specs include this helper at runtime via `rubocop/rspec/support`.
module CopHelper
  sig { params(source: String, file: T.untyped).returns(T::Array[T.untyped]) }
  def inspect_source(source, file = T.unsafe(nil)); end

  sig { params(source: String, file: T.untyped).returns(String) }
  def autocorrect_source(source, file = T.unsafe(nil)); end

  sig { params(source: String).returns(String) }
  def autocorrect_source_file(source); end

  sig { params(source: String, file: T.untyped).returns(T.untyped) }
  def parse_source(source, file = T.unsafe(nil)); end
end
