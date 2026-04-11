# typed: strict
# frozen_string_literal: true

# We intentionally want to have many exceptions in this file.
# rubocop:disable Style/OneClassPerFile

require "utils/output"

# Raised when a command is used wrong.
#
# @api internal
class UsageError < RuntimeError
  sig { returns(T.nilable(String)) }
  attr_reader :reason

  sig { params(reason: T.nilable(String)).void }
  def initialize(reason = nil)
    super

    @reason = T.let(reason, T.nilable(String))
  end

  sig { returns(String) }
  def to_s
    s = "Invalid usage"
    s += ": #{reason}" if reason
    s
  end
end

# Raised when a command expects a formula and none was specified.
class FormulaUnspecifiedError < UsageError
  sig { void }
  def initialize
    super "this command requires a formula argument"
  end
end

# Raised when a command expects a formula or cask and none was specified.
class FormulaOrCaskUnspecifiedError < UsageError
  sig { void }
  def initialize
    super "this command requires a formula or cask argument"
  end
end

# Raised when a command expects a keg and none was specified.
class KegUnspecifiedError < UsageError
  sig { void }
  def initialize
    super "this command requires a keg argument"
  end
end

class UnsupportedInstallationMethod < RuntimeError; end

class MultipleVersionsInstalledError < RuntimeError; end

# Raised when a path is not a keg.
#
# @api internal
class NotAKegError < RuntimeError; end

# Raised when a keg doesn't exist.
class NoSuchKegError < RuntimeError
  sig { returns(String) }
  attr_reader :name

  sig { returns(T.nilable(Tap)) }
  attr_reader :tap

  sig { params(name: String, tap: T.nilable(Tap)).void }
  def initialize(name, tap: nil)
    @name = T.let(name, String)
    @tap = T.let(tap, T.nilable(Tap))
    message = "No such keg: #{HOMEBREW_CELLAR}/#{name}"
    message += " from tap #{tap}" if tap
    super message
  end
end

# Raised when an invalid attribute is used in a formula.
class FormulaValidationError < StandardError
  sig { returns(T.any(Symbol, String)) }
  attr_reader :attr

  sig { returns(String) }
  attr_reader :formula

  sig { params(formula: String, attr: T.any(Symbol, String), value: T.untyped).void }
  def initialize(formula, attr, value)
    @attr = T.let(attr, T.any(Symbol, String))
    @formula = T.let(formula, String)
    super "invalid attribute for formula '#{formula}': #{attr} (#{value.inspect})"
  end
end

class LegacyDSLError < StandardError
  sig { returns(Symbol) }
  attr_reader :attr

  sig { params(attr: Symbol, value: T.untyped).void }
  def initialize(attr, value)
    @attr = T.let(attr, Symbol)
    super "A legacy DSL was used: #{attr} (#{value.inspect})"
  end
end

class FormulaSpecificationError < StandardError; end

# Raised when a deprecated method is used.
class MethodDeprecatedError < StandardError
  sig { returns(T.nilable(String)) }
  attr_accessor :issues_url
end

# Raised when neither a formula nor a cask with the given name is available.
class FormulaOrCaskUnavailableError < RuntimeError
  sig { returns(String) }
  attr_reader :name

  sig { params(name: String).void }
  def initialize(name)
    super()

    @name = T.let(name, String)

    # Store the state of these envs at the time the exception is thrown.
    # This is so we do the fuzzy search for "did you mean" etc under that same mode,
    # in case the list of formulae are different.
    @without_api = T.let(Homebrew::EnvConfig.no_install_from_api?, T::Boolean)
    @auto_without_api = T.let(Homebrew::EnvConfig.automatically_set_no_install_from_api?, T::Boolean)
  end

  sig { returns(String) }
  def did_you_mean
    require "formula"

    similar_formula_names = Homebrew.with_no_api_env_if_needed(@without_api) { Formula.fuzzy_search(name) }
    return "" if similar_formula_names.blank?

    "Did you mean #{similar_formula_names.to_sentence two_words_connector: " or ", last_word_connector: " or "}?"
  end

  sig { returns(String) }
  def to_s
    s = "No available formula or cask with the name \"#{name}\". #{did_you_mean}".strip
    if @auto_without_api && !CoreTap.instance.installed?
      s += "\nA full git tap clone is required to use this command on core packages."
    end
    s
  end
end

# Raised when a formula or cask in a specific tap is not available.
class TapFormulaOrCaskUnavailableError < FormulaOrCaskUnavailableError
  sig { returns(Tap) }
  attr_reader :tap

  sig { params(tap: Tap, name: String).void }
  def initialize(tap, name)
    super "#{tap}/#{name}"
    @tap = T.let(tap, Tap)
  end

  sig { returns(String) }
  def to_s
    s = super
    unless tap.installed?
      s += "\nThis command requires the tap #{tap}."
      s += "\nIf you trust this tap, tap it explicitly and then try again:\n  brew tap #{tap}"
    end
    s
  end
end

# Raised when a formula is not available.
#
# @api internal
class FormulaUnavailableError < FormulaOrCaskUnavailableError
  sig { returns(T.nilable(String)) }
  attr_accessor :dependent

  sig { returns(T.nilable(String)) }
  def dependent_s
    " (dependency of #{dependent})" if dependent && dependent != name
  end

  sig { returns(String) }
  def to_s
    "No available formula with the name \"#{name}\"#{dependent_s}. #{did_you_mean}".strip
  end
end

# Shared methods for formula class errors.
module FormulaClassUnavailableErrorModule
  extend T::Helpers

  abstract!

  sig { abstract.returns(T.any(Pathname, String)) }
  def path; end

  sig { abstract.returns(String) }
  def class_name; end

  sig { abstract.returns(T::Array[T.untyped]) }
  def class_list; end

  sig { returns(String) }
  def to_s
    s = super
    s += "\nIn formula file: #{path}"
    s += "\nExpected to find class #{class_name}, but #{class_list_s}."
    s
  end

  private

  sig { returns(String) }
  def class_list_s
    formula_class_list = class_list.select { |klass| klass < Formula }
    if class_list.empty?
      "found no classes"
    elsif formula_class_list.empty?
      "only found: #{format_list(class_list)} (not derived from Formula!)"
    else
      "only found: #{format_list(formula_class_list)}"
    end
  end

  sig { params(class_list: T::Array[T.untyped]).returns(String) }
  def format_list(class_list)
    class_list.map { |klass| klass.name.split("::").last }.join(", ")
  end
end

# Raised when a formula does not contain a formula class.
class FormulaClassUnavailableError < FormulaUnavailableError
  include FormulaClassUnavailableErrorModule

  sig { override.returns(T.any(Pathname, String)) }
  attr_reader :path

  sig { override.returns(String) }
  attr_reader :class_name

  sig { override.returns(T::Array[T.untyped]) }
  attr_reader :class_list

  sig { params(name: String, path: T.any(Pathname, String), class_name: String, class_list: T::Array[T.untyped]).void }
  def initialize(name, path, class_name, class_list)
    @path = T.let(path, T.any(Pathname, String))
    @class_name = T.let(class_name, String)
    @class_list = T.let(class_list, T::Array[T.untyped])
    super name
  end
end

# Shared methods for formula unreadable errors.
module FormulaUnreadableErrorModule
  extend T::Helpers

  abstract!
  requires_ancestor { FormulaOrCaskUnavailableError }

  sig { abstract.returns(Exception) }
  def formula_error; end

  sig { returns(String) }
  def to_s
    "#{name}: " + formula_error.to_s
  end
end

# Raised when a formula is unreadable.
class FormulaUnreadableError < FormulaUnavailableError
  include FormulaUnreadableErrorModule

  sig { override.returns(Exception) }
  attr_reader :formula_error

  sig { params(name: String, error: Exception).void }
  def initialize(name, error)
    super(name)
    @formula_error = T.let(error, Exception)
    set_backtrace(error.backtrace)
  end
end

# Raised when a formula in a specific tap is unavailable.
class TapFormulaUnavailableError < FormulaUnavailableError
  sig { returns(Tap) }
  attr_reader :tap

  sig { returns(String) }
  attr_reader :user

  sig { returns(String) }
  attr_reader :repository

  sig { params(tap: Tap, name: String).void }
  def initialize(tap, name)
    @tap = T.let(tap, Tap)
    @user = T.let(tap.user, String)
    @repository = T.let(tap.repository, String)
    super "#{tap}/#{name}"
  end

  sig { returns(String) }
  def to_s
    s = super
    unless tap.installed?
      s += "\nThis command requires the tap #{tap}."
      s += "\nIf you trust this tap, tap it explicitly and then try again:\n  brew tap #{tap}"
    end
    s
  end
end

# Raised when a formula in a specific tap does not contain a formula class.
class TapFormulaClassUnavailableError < TapFormulaUnavailableError
  include FormulaClassUnavailableErrorModule

  sig { override.returns(T.any(Pathname, String)) }
  attr_reader :path

  sig { override.returns(String) }
  attr_reader :class_name

  sig { override.returns(T::Array[T.untyped]) }
  attr_reader :class_list

  sig { params(tap: Tap, name: String, path: T.any(Pathname, String), class_name: String, class_list: T::Array[T.untyped]).void }
  def initialize(tap, name, path, class_name, class_list)
    @path = T.let(path, T.any(Pathname, String))
    @class_name = T.let(class_name, String)
    @class_list = T.let(class_list, T::Array[T.untyped])
    super tap, name
  end
end

# Raised when a formula in a specific tap is unreadable.
class TapFormulaUnreadableError < TapFormulaUnavailableError
  include FormulaUnreadableErrorModule

  sig { override.returns(Exception) }
  attr_reader :formula_error

  sig { params(tap: Tap, name: String, error: Exception).void }
  def initialize(tap, name, error)
    super(tap, name)
    @formula_error = T.let(error, Exception)
    set_backtrace(error.backtrace)
  end
end

# Raised when a formula with the same name is found in multiple taps.
class TapFormulaAmbiguityError < RuntimeError
  sig { returns(String) }
  attr_reader :name

  sig { returns(T::Array[Tap]) }
  attr_reader :taps

  sig { returns(T::Array[T.untyped]) }
  attr_reader :loaders

  sig { params(name: String, loaders: T::Array[T.untyped]).void }
  def initialize(name, loaders)
    @name = T.let(name, String)
    @loaders = T.let(loaders, T::Array[T.untyped])
    @taps = T.let(loaders.map(&:tap), T::Array[Tap])

    formulae = taps.map { |tap| "#{tap}/#{name}" }
    formula_list = formulae.map { |f| "\n       * #{f}" }.join

    super <<~EOS
      Formulae found in multiple taps:#{formula_list}

      Please use the fully-qualified name (e.g. #{formulae.first}) to refer to a specific formula.
    EOS
  end
end

# Raised when a tap is unavailable.
class TapUnavailableError < RuntimeError
  sig { returns(String) }
  attr_reader :name

  sig { params(name: String).void }
  def initialize(name)
    @name = T.let(name, String)

    message = "No available tap #{name}.\n"
    if [CoreTap.instance.name, CoreCaskTap.instance.name].include?(name)
      command = "brew tap --force #{name}"
      message += <<~EOS
        Run #{Formatter.identifier(command)} to tap #{name}!
      EOS
    else
      command = "brew tap-new #{name}"
      message += <<~EOS
        Run #{Formatter.identifier(command)} to create a new #{name} tap!
      EOS
    end
    super message.freeze
  end
end

# Raised when a tap's remote does not match the actual remote.
class TapRemoteMismatchError < RuntimeError
  sig { returns(String) }
  attr_reader :name

  sig { returns(T.nilable(String)) }
  attr_reader :expected_remote

  sig { returns(T.any(Pathname, String)) }
  attr_reader :actual_remote

  sig { params(name: String, expected_remote: T.nilable(String), actual_remote: T.any(Pathname, String)).void }
  def initialize(name, expected_remote, actual_remote)
    @name = T.let(name, String)
    @expected_remote = T.let(expected_remote, T.nilable(String))
    @actual_remote = T.let(actual_remote, T.any(Pathname, String))

    super message
  end

  sig { returns(String) }
  def message
    <<~EOS
      Tap #{name} remote mismatch.
      #{expected_remote} != #{actual_remote}
    EOS
  end
end

# Raised when the remote of homebrew/core does not match HOMEBREW_CORE_GIT_REMOTE.
class TapCoreRemoteMismatchError < TapRemoteMismatchError
  sig { override.returns(String) }
  def message
    <<~EOS
      Tap #{name} remote does not match `$HOMEBREW_CORE_GIT_REMOTE`.
      #{expected_remote} != #{actual_remote}
      Please set `HOMEBREW_CORE_GIT_REMOTE="#{actual_remote}"` and run `brew update` instead.
    EOS
  end
end

# Raised when a tap is already installed.
class TapAlreadyTappedError < RuntimeError
  sig { returns(String) }
  attr_reader :name

  sig { params(name: String).void }
  def initialize(name)
    @name = T.let(name, String)

    super <<~EOS
      Tap #{name} already tapped.
    EOS
  end
end

# Raised when run `brew tap --custom-remote` without a remote URL.
class TapNoCustomRemoteError < RuntimeError
  sig { returns(String) }
  attr_reader :name

  sig { params(name: String).void }
  def initialize(name)
    @name = T.let(name, String)

    super <<~EOS
      Tap #{name} with option `--custom-remote` but without a remote URL.
    EOS
  end
end

# Raised when another Homebrew operation is already in progress.
class OperationInProgressError < RuntimeError
  sig { params(locked_path: Pathname).void }
  def initialize(locked_path)
    full_command = Homebrew.running_command_with_args.presence || "brew"
    lock_context = if (env_lock_context = Homebrew::EnvConfig.lock_context.presence)
      "\n#{env_lock_context}"
    end
    message = <<~EOS
      A `#{full_command}` process has already locked #{locked_path}.#{lock_context}
      Please wait for it to finish or terminate it to continue.
    EOS

    super message
  end
end

class CannotInstallFormulaError < RuntimeError; end

# Raised when a formula installation was already attempted.
class FormulaInstallationAlreadyAttemptedError < RuntimeError
  sig { params(formula: Formula).void }
  def initialize(formula)
    super "Formula installation already attempted: #{formula.full_name}"
  end
end

# Raised when there are unsatisfied requirements.
class UnsatisfiedRequirements < RuntimeError
  sig { params(reqs: T.untyped).void }
  def initialize(reqs)
    if reqs.length == 1
      super "An unsatisfied requirement failed this build."
    else
      super "Unsatisfied requirements failed this build."
    end
  end
end

# Raised when a formula conflicts with another one.
class FormulaConflictError < RuntimeError
  sig { returns(Formula) }
  attr_reader :formula

  sig { returns(T::Array[T.untyped]) }
  attr_reader :conflicts

  sig { params(formula: Formula, conflicts: T::Array[T.untyped]).void }
  def initialize(formula, conflicts)
    @formula = T.let(formula, Formula)
    @conflicts = T.let(conflicts, T::Array[T.untyped])
    super message
  end

  sig { params(conflict: T.untyped).returns(String) }
  def conflict_message(conflict)
    message = []
    message << "  #{conflict.name}"
    message << ": because #{conflict.reason}" if conflict.reason
    message.join
  end

  sig { returns(String) }
  def message
    message = []
    message << "Cannot install #{formula.full_name} because conflicting formulae are installed."
    message.concat conflicts.map { |c| conflict_message(c) } << ""
    message << <<~EOS
      Please `brew unlink #{conflicts.map(&:name) * " "}` before continuing.

      Unlinking removes a formula's symlinks from #{HOMEBREW_PREFIX}. You can
      link the formula again after the install finishes. You can `--force` this
      install, but the build may fail or cause obscure side effects in the
      resulting software.
    EOS
    message.join("\n")
  end
end

# Raise when the Python version cannot be detected automatically.
class FormulaUnknownPythonError < RuntimeError
  sig { params(formula: T.untyped).void }
  def initialize(formula)
    super <<~EOS
      The version of Python to use with the virtualenv in the `#{formula.full_name}` formula
      cannot be guessed automatically because a recognised Python dependency could not be found.

      If you are using a non-standard Python dependency, please add `:using => "python@x.y"`
      to 'virtualenv_install_with_resources' to resolve the issue manually.
    EOS
  end
end

# Raise when two Python versions are detected simultaneously.
class FormulaAmbiguousPythonError < RuntimeError
  sig { params(formula: T.untyped).void }
  def initialize(formula)
    super <<~EOS
      The version of Python to use with the virtualenv in the `#{formula.full_name}` formula
      cannot be guessed automatically.

      If the simultaneous use of multiple Pythons is intentional, please add `:using => "python@x.y"`
      to 'virtualenv_install_with_resources' to resolve the ambiguity manually.
    EOS
  end
end

# Raised when an error occurs during a formula build.
class BuildError < RuntimeError
  include Utils::Output::Mixin

  sig { returns(T.any(String, Pathname)) }
  attr_reader :cmd

  sig { returns(T::Array[T.any(String, Integer, Pathname, Symbol)]) }
  attr_reader :args

  sig { returns(T::Hash[String, T.untyped]) }
  attr_reader :env

  sig { returns(T.nilable(Formula)) }
  attr_accessor :formula

  sig { returns(T.nilable(T::Array[String])) }
  attr_accessor :options

  sig {
    params(
      formula: T.nilable(Formula),
      cmd:     T.any(String, Pathname),
      args:    T::Array[T.any(String, Integer, Pathname, Symbol)],
      env:     T::Hash[String, T.untyped],
    ).void
  }
  def initialize(formula, cmd, args, env)
    @formula = T.let(formula, T.nilable(Formula))
    @cmd = T.let(cmd, T.any(String, Pathname))
    @args = T.let(args, T::Array[T.any(String, Integer, Pathname, Symbol)])
    @env = T.let(env, T::Hash[String, T.untyped])
    @options = T.let(nil, T.nilable(T::Array[String]))
    pretty_args = Array(args).map { |arg| arg.to_s.gsub(/[\\ ]/, "\\\\\\0") }.join(" ")
    super "Failed executing: #{cmd} #{pretty_args}".strip
  end

  sig { returns(T::Array[T.untyped]) }
  def issues
    @issues ||= T.let(fetch_issues, T.nilable(T::Array[T.untyped]))
  end

  sig { returns(T::Array[T.untyped]) }
  def fetch_issues
    return [] if ENV["HOMEBREW_NO_BUILD_ERROR_ISSUES"].present?

    formula = self.formula
    return [] unless formula

    GitHub.issues_for_formula(formula.name, tap: formula.tap, state: "open", type: "issue")
  rescue GitHub::API::Error => e
    opoo "Unable to query GitHub for recent issues on the tap\n#{e.message}"
    []
  end

  sig { params(verbose: T::Boolean).void }
  def dump(verbose: false)
    puts
    formula = self.formula
    return unless formula

    if verbose
      require "system_config"
      require "build_environment"

      ohai "Formula"
      puts "Tap: #{formula.tap}" if formula.tap?
      puts "Path: #{formula.path}"
      ohai "Configuration"
      SystemConfig.dump_verbose_config
      ohai "ENV"
      BuildEnvironment.dump env
      puts
      onoe "#{formula.full_name} #{formula.version} did not build"
      unless (logs = Dir["#{formula.logs}/*"]).empty?
        puts "Logs:"
        puts logs.map { |fn| "     #{fn}" }.join("\n")
      end
    end

    formula_tap = formula.tap
    if formula_tap
      if OS.not_tier_one_configuration?
        <<~EOS
          This is not a Tier 1 configuration:
            #{Formatter.url("https://docs.brew.sh/Support-Tiers")}
          #{Formatter.bold("Do not report any issues to Homebrew/* repositories!")}
          Read the above document instead before opening any issues or PRs.
        EOS
      elsif formula_tap.official?
        puts Formatter.error(Formatter.url(OS::ISSUES_URL), label: "READ THIS")
      elsif (issues_url = formula_tap.issues_url)
        puts <<~EOS
          If reporting this issue please do so at (not Homebrew/* repositories):
            #{Formatter.url(issues_url)}
        EOS
      else
        puts <<~EOS
          If reporting this issue please do so to (not Homebrew/* repositories):
            #{formula_tap}
        EOS
      end
    else
      <<~EOS
        We cannot detect the correct tap to report this issue to.
        Do not report this issue to Homebrew/* repositories!
      EOS
    end

    puts

    if issues.present?
      puts "These open issues may also help:"
      puts issues.map { |i| "#{i["title"]} #{i["html_url"]}" }.join("\n")
    end

    require "diagnostic"
    checks = Homebrew::Diagnostic::Checks.new
    checks.build_error_checks.each do |check|
      out = checks.send(check)
      next if out.nil?

      puts
      ofail out
    end
  end
end

# Raised if the formula or its dependencies are not bottled and are being
# installed in a situation where a bottle is required.
class UnbottledError < RuntimeError
  sig { params(formulae: T::Array[Formula]).void }
  def initialize(formulae)
    require "utils"

    msg = <<~EOS
      The following #{Utils.pluralize("formula", formulae.count)} cannot be installed from #{Utils.pluralize("bottle", formulae.count)} and must be
      built from source.
        #{formulae.to_sentence}
    EOS
    msg += "#{DevelopmentTools.installation_instructions}\n" unless DevelopmentTools.installed?
    msg.freeze
    super(msg)
  end
end

# Raised by `Homebrew.install`, `Homebrew.reinstall` and `Homebrew.upgrade`
# if the user passes any flags/environment that would case a bottle-only
# installation on a system without build tools to fail.
class BuildFlagsError < RuntimeError
  sig { params(flags: T::Array[String], bottled: T::Boolean).void }
  def initialize(flags, bottled: true)
    if flags.length > 1
      flag_text = "flags"
      require_text = "require"
    else
      flag_text = "flag"
      require_text = "requires"
    end

    bottle_text = if bottled
      <<~EOS
        Alternatively, remove the #{flag_text} to attempt bottle installation.
      EOS
    end

    message = <<~EOS
      The following #{flag_text}:
        #{flags.join(", ")}
      #{require_text} building tools, but none are installed.
      #{DevelopmentTools.installation_instructions} #{bottle_text}
    EOS

    super message
  end
end

# Raised by {CompilerSelector} if the formula fails with all of
# the compilers available on the user's system.
class CompilerSelectionError < RuntimeError
  sig { params(formula: T.any(Formula, SoftwareSpec)).void }
  def initialize(formula)
    super <<~EOS
      #{formula.full_name} cannot be built with any available compilers.
      #{DevelopmentTools.custom_installation_instructions}
    EOS
  end
end

# Raised in {Downloadable#fetch}.
class DownloadError < RuntimeError
  sig { returns(Exception) }
  attr_reader :cause

  sig { params(downloadable: T.untyped, cause: Exception).void }
  def initialize(downloadable, cause)
    super <<~EOS
      Failed to download resource #{downloadable.download_queue_name.inspect}
      #{cause.message}
    EOS
    @cause = T.let(cause, Exception)
    set_backtrace(cause.backtrace)
  end
end

# Raised in {CurlDownloadStrategy#fetch}.
class CurlDownloadStrategyError < RuntimeError
  sig { params(url: String, details: T.nilable(String)).void }
  def initialize(url, details = nil)
    suffix = "\n#{details}" if details.present?
    case url
    when %r{^file://(.+)}
      super "File cannot be read: #{Regexp.last_match(1)}#{suffix}"
    else
      super "Download failed: #{url}#{suffix}"
    end
  end
end

# Raised in {HomebrewCurlDownloadStrategy#fetch}.
class HomebrewCurlDownloadStrategyError < CurlDownloadStrategyError
  sig { params(url: String).void }
  def initialize(url)
    super "Homebrew-installed `curl` is not installed for: #{url}"
  end
end

# Raised by {Kernel#safe_system} in `utils.rb`.
class ErrorDuringExecution < RuntimeError
  sig { returns(T::Array[T.untyped]) }
  attr_reader :cmd

  sig { returns(T.untyped) }
  attr_reader :status

  sig { returns(T.nilable(T::Array[T.untyped])) }
  attr_reader :output

  sig {
    params(
      cmd:     T::Array[T.untyped],
      status:  T.untyped,
      output:  T.nilable(T::Array[T.untyped]),
      secrets: T::Array[String],
    ).void
  }
  def initialize(cmd, status:, output: nil, secrets: [])
    @cmd = T.let(cmd, T::Array[T.untyped])
    @status = T.let(status, T.untyped)
    @output = T.let(output, T.nilable(T::Array[T.untyped]))

    raise ArgumentError, "Status cannot be nil." if status.nil?

    exitstatus = case status
    when Integer
      status
    when Hash
      status["exitstatus"]
    else
      status.exitstatus
    end

    termsig = case status
    when Integer
      nil
    when Hash
      status["termsig"]
    else
      status.termsig
    end

    redacted_cmd = Formatter.redact_secrets(cmd.shelljoin.gsub('\=', "="), secrets)

    reason = if exitstatus
      "exited with #{exitstatus}"
    elsif termsig
      "was terminated by uncaught signal #{Signal.signame(termsig)}"
    else
      raise ArgumentError, "Status neither has `exitstatus` nor `termsig`."
    end

    s = "Failure while executing; `#{redacted_cmd}` #{reason}."

    if Array(output).present?
      format_output_line = lambda do |type_line|
        type, line = *type_line
        if type == :stderr
          Formatter.error(line)
        else
          line
        end
      end

      s << " Here's the output:\n"
      s << Array(output).map(&format_output_line).join
      s << "\n" unless s.end_with?("\n")
    end

    super s.freeze
  end

  sig { returns(String) }
  def stderr
    Array(output).select { |type,| type == :stderr }.map(&:last).join
  end
end

# Raised by {Pathname#verify_checksum} when "expected" is nil or empty.
class ChecksumMissingError < ArgumentError; end

# Raised by {Pathname#verify_checksum} when verification fails.
class ChecksumMismatchError < RuntimeError
  sig { returns(T.untyped) }
  attr_reader :expected

  sig { params(path: T.any(Pathname, String), expected: T.untyped, actual: T.untyped).void }
  def initialize(path, expected, actual)
    @expected = T.let(expected, T.untyped)

    super <<~EOS
      SHA-256 mismatch
      Expected: #{Formatter.success(expected.to_s)}
        Actual: #{Formatter.error(actual.to_s)}
          File: #{path}
      To retry an incomplete download, remove the file above.
    EOS
  end
end

# Raised when a resource is missing.
class ResourceMissingError < ArgumentError
  sig { params(formula: T.untyped, resource: T.untyped).void }
  def initialize(formula, resource)
    super "#{formula.full_name} does not define resource #{resource.inspect}"
  end
end

# Raised when a resource is specified multiple times.
class DuplicateResourceError < ArgumentError
  sig { params(resource: T.untyped).void }
  def initialize(resource)
    super "Resource #{resource.inspect} is defined more than once"
  end
end

# Raised when a single patch file is not found and apply hasn't been specified.
class MissingApplyError < RuntimeError; end

# Raised when a bottle does not contain a formula file.
class BottleFormulaUnavailableError < RuntimeError
  sig { params(bottle_path: T.any(Pathname, String), formula_path: T.any(Pathname, String)).void }
  def initialize(bottle_path, formula_path)
    super <<~EOS
      This bottle does not contain the formula file:
        #{bottle_path}
        #{formula_path}
    EOS
  end
end

# Raised when a `Utils.safe_fork` exits with a non-zero code.
class ChildProcessError < RuntimeError
  sig { returns(Process::Status) }
  attr_reader :status

  sig { params(status: Process::Status).void }
  def initialize(status)
    @status = T.let(status, Process::Status)

    super "Forked child process failed: #{status}"
  end
end

# Raised when `detected_perl_shebang` etc cannot detect the shebang.
class ShebangDetectionError < RuntimeError
  sig { params(type: String, reason: String).void }
  def initialize(type, reason)
    super "Cannot detect #{type} shebang: #{reason}."
  end
end

# Raised when one or more formulae have cyclic dependencies.
class CyclicDependencyError < RuntimeError
  sig { params(strongly_connected_components: T::Array[T.untyped]).void }
  def initialize(strongly_connected_components)
    super <<~EOS
      The following packages contain cyclic dependencies:
        #{strongly_connected_components.select { |packages| packages.count > 1 }.map(&:to_sentence).join("\n  ")}
    EOS
  end
end

# rubocop:enable Style/OneClassPerFile
