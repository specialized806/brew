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
  include Test::Helper::IntegrationTest
  include Test::Helper::MkTmpDir
  include Test::Helper::Subcommand
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
