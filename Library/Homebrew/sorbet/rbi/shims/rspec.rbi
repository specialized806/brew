# typed: strict

class RSpec::Core::ExampleGroup
  include CopHelper
  include RSpec::SharedContext
  include RSpec::Matchers
  include RSpec::Mocks::ExampleMethods
  include RuboCop::RSpec::ExpectOffense
  include Test::Helper::Cask
  include Test::Helper::Fixtures
  include Test::Helper::Formula
  include Test::Helper::MkTmpDir
  include Test::Helper::Subcommand
  include Test::Helper::Fixtures

  # These methods are added to specs in
  # `test/support/helper/spec/shared_context/integration_test.rb`; declare them
  # here so Sorbet can resolve them in typed spec files.
  sig { params(args: T.untyped).returns(Process::Status) }
  def brew(*args); end

  sig { params(args: T.untyped).returns(Process::Status) }
  def brew_sh(*args); end

  sig {
    params(
      name:           String,
      content:        T.nilable(String),
      tap:            Tap,
      bottle_block:   T.nilable(String),
      tab_attributes: T.nilable(T::Hash[T.untyped, T.untyped]),
    ).returns(Pathname)
  }
  def setup_test_formula(name, content = T.unsafe(nil), tap: T.unsafe(nil), bottle_block: T.unsafe(nil),
                         tab_attributes: T.unsafe(nil))
  end

  sig { returns(Pathname) }
  def setup_test_tap; end

  sig { params(name: String, content: T.nilable(String), build_bottle: T::Boolean).void }
  def install_test_formula(name, content = T.unsafe(nil), build_bottle: false); end

  sig { params(old_name: String, new_name: String).void }
  def install_and_rename_coretap_formula(old_name, new_name); end

  sig { params(name: String).void }
  def uninstall_test_formula(name); end
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
