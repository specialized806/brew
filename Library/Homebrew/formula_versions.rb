# typed: strict
# frozen_string_literal: true

require "formula"
require "utils/output"

# Helper class for traversing a formula's previous versions.
#
# @api internal
class FormulaVersions
  include Context
  include Utils::Output::Mixin

  # Parses bottle syntax that was removed in February 2021 without exposing it
  # to normal formula loading.
  class LegacyBottleSpecification < BottleSpecification
    sig { override.void }
    def initialize
      super
      @legacy_cellar = T.let(nil, T.nilable(T.any(Symbol, String)))
    end

    sig { override.params(hash: T::Hash[T.any(Symbol, String), T.any(String, Symbol)]).void }
    def sha256(hash)
      legacy = hash.find do |key, value|
        key.is_a?(String) && key.match?(/^[a-f0-9]{64}$/i) && value.is_a?(Symbol)
      end
      return super if legacy.nil?

      digest, tag = legacy
      converted = T.let({ tag => digest }, T::Hash[T.any(Symbol, String), T.any(String, Symbol)])
      cellar = hash[:cellar] || @legacy_cellar
      converted[:cellar] = cellar unless cellar.nil?
      super(converted)
    end

    sig { params(value: T.any(Symbol, String)).returns(T.any(Symbol, String)) }
    def cellar(value)
      @legacy_cellar = value
    end
  end

  @legacy_formula_class = T.let(nil, T.nilable(T.class_of(Formula)))

  sig { returns(T.class_of(Formula)) }
  def self.legacy_formula_class
    @legacy_formula_class ||= Class.new(Formula) do
      class << self
        define_method(:inherited) do |child|
          super(child)
          child.stable&.instance_variable_set(:@bottle_specification, LegacyBottleSpecification.new)
        end
      end
    end
  end

  IGNORED_EXCEPTIONS = [
    ArgumentError, NameError, SyntaxError, TypeError, LegacyDSLError,
    FormulaSpecificationError, FormulaValidationError,
    ErrorDuringExecution, LoadError, MethodDeprecatedError
  ].freeze

  sig { params(formula: Formula).void }
  def initialize(formula)
    @name = T.let(formula.name, String)
    @path = T.let(formula.tap_path, Pathname)
    @repository = T.let(formula.tap!.path, Pathname)
    @relative_path = T.let(@path.relative_path_from(repository).to_s, String)
    # Also look at e.g. older homebrew-core paths before sharding.
    if (match = @relative_path.match(%r{^(HomebrewFormula|Formula)/(?:[a-z]|lib)/(.+)}))
      @old_relative_path = T.let("#{match[1]}/#{match[2]}", T.nilable(String))
    end
    @formula_at_revision = T.let({}, T::Hash[String, Formula])
  end

  sig { params(branch: String, _block: T.proc.params(revision: String, path: String).void).void }
  def rev_list(branch, &_block)
    repository.cd do
      rev_list_cmd = ["git", "rev-list", "--abbrev-commit", "--remove-empty"]
      [relative_path, old_relative_path].compact.each do |entry|
        Utils.popen_read(*rev_list_cmd, branch, "--", entry) do |io|
          yield io.readline.chomp, entry until io.eof?
        end
      end
    end
  end

  sig {
    type_parameters(:U)
      .params(
        revision:              String,
        formula_relative_path: String,
        _block:                T.proc.params(arg0: Formula).returns(T.type_parameter(:U)),
      ).returns(T.nilable(T.type_parameter(:U)))
  }
  def formula_at_revision(revision, formula_relative_path = relative_path, &_block)
    Homebrew.raise_deprecation_exceptions = true

    formula = @formula_at_revision[revision] || begin
      nostdout do
        Formulary.from_contents(
          name,
          path,
          file_contents_at_revision(revision, formula_relative_path)
            .sub(/\A(?:(?:[ \t]*#[^\n]*\n|[ \t]*\n)|(?:=begin[^\n]*(?:\n|\z).*?^=end[^\n]*(?:\n|\z)))*/m) do |header|
              "#{header}Formula = ::FormulaVersions.legacy_formula_class;"
            end,
          ignore_errors: true,
        )
      end
    rescue FormulaUnavailableError
      nil
    rescue Homebrew::UntrustedTapError, MacOSVersion::Error
      raise
    rescue StandardError, ScriptError => e
      raise if Homebrew::EnvConfig.disable_load_formula?

      require "utils/backtrace"

      # We rescue these so that we can skip bad versions and
      # continue walking the history
      odebug "#{e} in #{name} at revision #{revision}", Utils::Backtrace.clean(e)
      nil
    end

    return if formula.nil?

    @formula_at_revision[revision] = formula
    yield formula
  ensure
    Homebrew.raise_deprecation_exceptions = false
  end

  private

  sig { returns(String) }
  attr_reader :name, :relative_path

  sig { returns(T.nilable(String)) }
  attr_reader :old_relative_path

  sig { returns(Pathname) }
  attr_reader :path, :repository

  sig { params(revision: String, relative_path: String).returns(String) }
  def file_contents_at_revision(revision, relative_path)
    repository.cd { Utils.popen_read("git", "cat-file", "blob", "#{revision}:#{relative_path}") }
  end

  sig {
    type_parameters(:U)
      .params(block: T.proc.returns(T.type_parameter(:U)))
      .returns(T.type_parameter(:U))
  }
  def nostdout(&block)
    if verbose?
      yield
    else
      Utils::Output.redirect_stdout(File::NULL, &block)
    end
  end
end
