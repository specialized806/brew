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

  # Historical metadata is inspected, never downloaded using these obsolete checksums.
  module LegacyChecksums
    sig { params(_value: T.any(String, T::Hash[String, Symbol])).void }
    def sha1(_value); end

    sig { params(_value: T.any(String, T::Hash[String, Symbol])).void }
    def md5(_value); end
  end

  class LegacyResource < Resource
    include LegacyChecksums

    sig {
      override.params(strip: T.any(Symbol, String), src: T.nilable(T.any(Symbol, String)),
                      block: T.nilable(T.proc.bind(Resource::Patch).void))
              .returns(T::Array[T.any(EmbeddedPatch, ExternalPatch)])
    }
    def patch(strip = :p1, src = nil, &block)
      super(strip, src, &(FormulaVersions.legacy_patch_block(block) if block))
    end
  end

  module LegacySoftwareSpec
    extend T::Helpers
    include LegacyChecksums

    requires_ancestor { SoftwareSpec }

    sig {
      params(name: T.nilable(String), klass: T.class_of(Resource),
             block: T.nilable(T.proc.bind(Resource).void)).returns(T.nilable(Resource))
    }
    def resource(name = nil, klass = Resource, &block)
      super(name, (klass == Resource) ? LegacyResource : klass, &block)
    end

    sig {
      params(strip: T.any(Symbol, String), src: T.nilable(T.any(Symbol, String)),
             block: T.nilable(T.proc.bind(Resource::Patch).void)).void
    }
    def patch(strip = :p1, src = nil, &block)
      super(strip, src, &(FormulaVersions.legacy_patch_block(block) if block))
    end
  end

  # Extend each historical patch resource before evaluating its declarations.
  sig { params(block: T.proc.void).returns(T.proc.void) }
  def self.legacy_patch_block(block)
    proc do
      T.bind(self, Resource::Patch)
      extend LegacyChecksums

      instance_eval(&block)
    end
  end

  # Parses bottle syntax that was removed in February 2021 without exposing it
  # to normal formula loading.
  class LegacyBottleSpecification < BottleSpecification
    include LegacyChecksums

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

    sig { params(_value: Integer).void }
    def revision(_value); end

    sig { params(value: T.any(Symbol, String)).returns(T.any(Symbol, String)) }
    def cellar(value)
      @legacy_cellar = value
    end
  end

  @legacy_formula_class = T.let(nil, T.nilable(T.class_of(Formula)))

  sig { returns(T.class_of(Formula)) }
  def self.legacy_formula_class
    @legacy_formula_class ||= Class.new(Formula) do
      extend LegacyChecksums

      class << self
        define_method(:devel) { nil }
        define_method(:plist_options) { |**_options| nil }
        # Historical option checks must fail the load, not exit the consumer.
        define_method(:odie) { |error| raise FormulaSpecificationError, error.to_s }
        define_method(:bottle) do |*args, &block|
          next if args == [:unneeded] && block.nil?

          super(*args, &block)
        end

        define_method(:inherited) do |child|
          super(child)
          [child.stable, child.head].compact.each do |spec|
            spec.extend(LegacySoftwareSpec)
            spec.instance_variable_set(:@bottle_specification, LegacyBottleSpecification.new)
          end
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
    @load_error = T.let(nil, T.nilable(Exception))
  end

  # The original error from the most recent failed historical load.
  sig { returns(T.nilable(Exception)) }
  attr_reader :load_error

  # Full history includes earlier lifetimes of a deleted and re-added path.
  # Vulns::History skips proven absent paths, which are not formula builds.
  sig {
    params(branch: String, all_history: T::Boolean, _block: T.proc.params(revision: String, path: String).void).void
  }
  def rev_list(branch, all_history: false, &_block)
    repository.cd do
      rev_list_cmd = ["git", "rev-list", "--abbrev-commit"]
      rev_list_cmd << "--remove-empty" unless all_history
      [relative_path, old_relative_path].compact.each do |entry|
        Utils.popen_read(*rev_list_cmd, branch, "--", entry, safe: all_history)
             .each_line(chomp: true) { |revision| yield revision, entry }
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
    @load_error = nil
    Homebrew.raise_deprecation_exceptions = true

    # rev_list visits the current path first. At a sharding rename, the old
    # path is absent in the same commit; reuse the already-loaded new path.
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
    rescue FormulaUnavailableError => e
      @load_error = e.cause || e
      nil
    rescue Homebrew::UntrustedTapError, MacOSVersion::Error
      raise
    rescue StandardError, ScriptError => e
      @load_error = e
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

  # Only a successful tree lookup proves absence; a failed Git command must
  # not turn unreadable history into a skipped revision.
  sig { params(revision: String, relative_path: String).returns(T::Boolean) }
  def path_absent_at_revision?(revision, relative_path)
    repository.cd do
      Utils.popen_read("git", "ls-tree", "--full-tree", "--name-only", "-z",
                       revision, "--", relative_path, safe: true).empty?
    end
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
