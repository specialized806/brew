# typed: strict
# frozen_string_literal: true

require "bundle/dsl"
require "bundle/package_types"
require "bundle/skipper"
require "bundle/trust"
require "trust"
require "utils/output"

module Homebrew
  module Bundle
    module Installer
      extend ::Utils::Output::Mixin

      class InstallableEntry < T::Struct
        const :name, String
        const :options, Homebrew::Bundle::EntryOptions
        const :verb, String
        const :cls, T.class_of(Homebrew::Bundle::PackageType)

        sig { returns(String) }
        def full_name
          T.cast(options.fetch(:full_name, name), String)
        end

        sig { returns(T.nilable(String)) }
        def tap_name
          ::Utils.tap_from_full_name(full_name)
        end
      end

      sig { void }
      def self.reset!
        Homebrew::Bundle.reset!
        Homebrew::Bundle::Cask.reset!
        Homebrew::Bundle::Tap.reset!
      end

      sig {
        params(
          entries:    T::Array[Dsl::Entry],
          global:     T::Boolean,
          file:       T.nilable(String),
          no_lock:    T::Boolean,
          no_upgrade: T::Boolean,
          verbose:    T::Boolean,
          force:      T::Boolean,
          quiet:      T::Boolean,
        ).returns(T::Boolean)
      }
      def self.install!(entries, global: false, file: nil, no_lock: false, no_upgrade: false, verbose: false,
                        force: false, quiet: false)
        success = 0
        failure = 0

        installable_entries = T.let([], T::Array[InstallableEntry])
        installable_brewfile_entries = T.let([], T::Array[Dsl::Entry])
        entries.each do |entry|
          next if Homebrew::Bundle::Skipper.skip? entry

          name = entry.name
          options = entry.options
          type = entry.type
          cls = Homebrew::Bundle.installable(type)
          next if cls.nil? || !cls.install_supported?

          installable_brewfile_entries << entry
          installable_entries << InstallableEntry.new(name:, options:, verb: cls.install_verb(name, options), cls:)
        end

        # Apply `trusted: true` Brewfile options before anything fetches or
        # loads the entries: the fetch phase and upgrade checks load formulae
        # and casks, which triggers the tap trust check before the per-entry
        # install step could grant trust.
        Homebrew::Bundle::Trust.entries(installable_brewfile_entries).each do |type, name|
          Homebrew::Trust.trust!(type, name)
        end

        if (fetchable_names = fetchable_formulae_and_casks(installable_entries, no_upgrade:).presence)
          fetchable_names_joined = fetchable_names.join(", ")
          puts Formatter.success("Fetching #{fetchable_names_joined}") unless quiet
          unless Bundle.brew("fetch", *fetchable_names, verbose:)
            $stderr.puts Formatter.error "`brew bundle` failed! Failed to fetch #{fetchable_names_joined}"
            return false
          end
        end

        # Taps first: later entries can live in them, and `ensure_installed!` below
        # needs the ones the Brewfile itself provides to already be present.
        tap_entries, pending_entries = installable_entries.partition { |entry| entry.cls == Tap }
        tap_entries.each do |entry|
          if install_entry!(entry, no_upgrade:, verbose:, force:, quiet:)
            success += 1
          else
            failure += 1
          end
        end
        ::Tap.clear_cache if tap_entries.present?
        installed_taps = ensure_entry_taps_installed!(pending_entries, tap_entries:)
        prepare_attestation_verification!(pending_entries)

        batchable, remaining = pending_entries.partition do |entry|
          batchable?(entry, entries: pending_entries, installed_taps:)
        end

        if batchable.present?
          batch_success, batch_failure = batch_install!(batchable, no_upgrade:, verbose:, force:, quiet:)
          success += batch_success
          failure += batch_failure
        end

        remaining.each do |entry|
          if install_entry!(entry, no_upgrade:, verbose:, force:, quiet:)
            success += 1
          else
            failure += 1
          end
        end

        unless failure.zero?
          require "utils"
          dependency = Utils.pluralize("dependency", failure)
          $stderr.puts Formatter.error "`brew bundle` failed! #{failure} Brewfile #{dependency} failed to install"
          return false
        end

        unless quiet
          require "utils"
          dependency = Utils.pluralize("dependency", success)
          puts Formatter.success "`brew bundle` complete! #{success} Brewfile #{dependency} now installed."
        end

        true
      end

      sig {
        params(
          entries:    T::Array[InstallableEntry],
          no_upgrade: T::Boolean,
        ).returns(T::Array[String])
      }
      def self.fetchable_formulae_and_casks(entries, no_upgrade:)
        installed_taps = Tap.installed_taps

        entries.filter_map do |entry|
          next if tap_dependencies(entry, entries:, installed_taps:).present?

          entry.cls.fetchable_name(entry.name, entry.options, no_upgrade:)
        end
      end

      sig {
        params(
          entry:          InstallableEntry,
          entries:        T::Array[InstallableEntry],
          installed_taps: T::Array[String],
        ).returns(T::Array[String])
      }
      def self.tap_dependencies(entry, entries:, installed_taps:)
        return [] unless [Brew, Cask].include?(entry.cls)

        if (tap_name = entry.tap_name)
          return installed_taps.exclude?(tap_name) ? [tap_name] : []
        end

        tap_names = entries.filter_map do |tap_entry|
          tap_entry.name if tap_entry.cls == Tap && installed_taps.exclude?(tap_entry.name)
        end
        return [] if tap_names.empty?
        return [] unless unavailable_without_tap?(entry)

        tap_names
      end

      sig { params(entry: InstallableEntry).returns(T::Boolean) }
      def self.unavailable_without_tap?(entry)
        require "api"

        case entry.cls.name
        when "Homebrew::Bundle::Brew"
          !Homebrew::API.formula_name?(entry.name) &&
            Homebrew::API.formula_aliases.exclude?(entry.name) &&
            Homebrew::API.formula_renames.exclude?(entry.name)
        when "Homebrew::Bundle::Cask"
          !Homebrew::API.cask_token?(entry.name) &&
            Homebrew::API.cask_renames.exclude?(entry.name)
        else
          false
        end
      rescue => e
        opoo "Treating `#{entry.name}` as dependent on Brewfile taps because Homebrew could not " \
             "check API metadata: #{e}"
        true
      end
      private_class_method :unavailable_without_tap?

      # Installs the taps that entries live in but the Brewfile does not list, returning
      # the names of every tap now installed.
      sig {
        params(
          entries:     T::Array[InstallableEntry],
          tap_entries: T::Array[InstallableEntry],
        ).returns(T::Array[String])
      }
      def self.ensure_entry_taps_installed!(entries, tap_entries:)
        require "tap"

        installed_taps = Tap.installed_taps
        entries.each do |entry|
          tap_with_name = case entry.cls.name
          when "Homebrew::Bundle::Brew" then ::Tap.with_formula_name(entry.full_name)
          when "Homebrew::Bundle::Cask" then ::Tap.with_cask_token(entry.full_name)
          end
          next unless tap_with_name

          tap = tap_with_name.first
          next if installed_taps.include?(tap.name)
          next if tap_entries.any? { |tap_entry| tap_entry.name == tap.name }

          tap.ensure_installed!
          installed_taps << tap.name
        end
        installed_taps
      end
      private_class_method :ensure_entry_taps_installed!

      # Resolve `gh` up front when it is needed to verify attestations, so that the
      # batched install does not have to.
      sig { params(entries: T::Array[InstallableEntry]).void }
      def self.prepare_attestation_verification!(entries)
        return unless Homebrew::EnvConfig.verify_attestations?
        return unless entries.any? { |entry| [Brew, Cask].include?(entry.cls) }
        return if entries.any? { |entry| entry.cls == Brew && entry.name == "gh" }

        require "attestation"

        Homebrew::Attestation.gh_executable
      end
      private_class_method :prepare_attestation_verification!

      # Options that do not change the `brew install` command line, so entries carrying
      # only these can share one invocation.
      BATCHABLE_OPTION_KEYS = [:full_name, :trusted].freeze

      # Formula entries whose install is a plain `brew install <name>` can be batched.
      # Anything else keeps its own child process, because it either passes extra
      # arguments, needs work before or after the install, or is not a formula at all.
      sig {
        params(
          entry:          InstallableEntry,
          entries:        T::Array[InstallableEntry],
          installed_taps: T::Array[String],
        ).returns(T::Boolean)
      }
      def self.batchable?(entry, entries:, installed_taps:)
        return false if entry.cls != Brew
        return false if (entry.options.keys - BATCHABLE_OPTION_KEYS).any?
        return false if tap_dependencies(entry, entries:, installed_taps:).present?

        # One name that cannot be loaded would otherwise fail the whole invocation
        # before anything installs.
        require "formula"
        Formula[entry.full_name]
        true
      rescue
        false
      end
      private_class_method :batchable?

      # Installs every entry in one `brew install` and one `brew upgrade`, then finishes
      # each entry so its link state is still reconciled per entry.
      sig {
        params(
          entries:    T::Array[InstallableEntry],
          no_upgrade: T::Boolean,
          verbose:    T::Boolean,
          force:      T::Boolean,
          quiet:      T::Boolean,
        ).returns([Integer, Integer])
      }
      def self.batch_install!(entries, no_upgrade:, verbose:, force:, quiet:)
        actionable = entries.select do |entry|
          if Brew.preinstall!(entry.name, **entry.options, no_upgrade:, verbose:)
            puts Formatter.success("#{entry.verb} #{entry.name}")
            true
          else
            puts "Using #{entry.name}" unless quiet
            false
          end
        end

        upgradable, fresh = actionable.partition { |entry| Brew.formula_installed?(entry.name) }

        install_args = force ? ["--force", "--overwrite"] : []
        upgrade_args = force ? ["--force"] : []
        # Attempt both halves even if the first fails, like the per-entry path would.
        installed_ok = fresh.empty? ||
                       Bundle.brew("install", "--formula", *fresh.map(&:full_name), *install_args, verbose:)
        upgraded_ok = upgradable.empty? ||
                      Bundle.brew("upgrade", "--formula", *upgradable.map(&:name), *upgrade_args, verbose:)
        batch_succeeded = installed_ok && upgraded_ok

        # The batch changed what is installed, so the memoised views of it are stale and
        # `Brew.install!` below would skip the link and service steps for every entry.
        require "formula"
        Formula.clear_cache
        Brew.reset!

        success = 0
        failure = 0
        entries.each do |entry|
          # `brew install` exits non-zero if any package failed, so a successful batch
          # means every entry in it succeeded. Only when it failed do we have to ask what
          # ended up installed, since the exit status cannot name the entry that failed.
          entry_succeeded = batch_succeeded || Brew.formula_installed_and_up_to_date?(entry.name, no_upgrade:)
          if entry_succeeded &&
             Brew.install!(entry.name, **entry.options, preinstall: false, no_upgrade:, verbose:, force:)
            success += 1
          else
            $stderr.puts Formatter.error("#{entry.verb} #{entry.name} has failed!")
            failure += 1
          end
        end
        [success, failure]
      end
      private_class_method :batch_install!

      sig {
        params(
          entry:      InstallableEntry,
          no_upgrade: T::Boolean,
          verbose:    T::Boolean,
          force:      T::Boolean,
          quiet:      T::Boolean,
        ).returns(T::Boolean)
      }
      def self.install_entry!(entry, no_upgrade:, verbose:, force:, quiet:)
        name = entry.name
        options = entry.options
        verb = entry.verb
        cls = entry.cls

        preinstall = if cls.preinstall!(name, **options, no_upgrade:, verbose:)
          puts Formatter.success("#{verb} #{name}")
          true
        else
          puts "Using #{name}" unless quiet
          false
        end

        if cls.install!(name, **options,
                        preinstall:, no_upgrade:, verbose:, force:)
          true
        else
          $stderr.puts Formatter.error("#{verb} #{name} has failed!")
          false
        end
      end
      private_class_method :install_entry!
    end
  end
end
