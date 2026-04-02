# typed: strict
# frozen_string_literal: true

require "bundle/dsl"
require "bundle/package_types"
require "bundle/skipper"
require "set"

module Homebrew
  module Bundle
    module Installer
      class InstallableEntry < T::Struct
        const :name, String
        const :options, Homebrew::Bundle::EntryOptions
        const :verb, String
        const :cls, T.class_of(Homebrew::Bundle::PackageType)
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
          jobs:       Integer,
          quiet:      T::Boolean,
        ).returns(T::Boolean)
      }
      def self.install!(entries, global: false, file: nil, no_lock: false, no_upgrade: false, verbose: false,
                        force: false, jobs: 1, quiet: false)
        success = 0
        failure = 0

        installable_entries = entries.filter_map do |entry|
          next if Homebrew::Bundle::Skipper.skip? entry

          name = entry.name
          options = entry.options
          type = entry.type
          cls = Homebrew::Bundle.installable(type)
          next if cls.nil? || !cls.install_supported?

          InstallableEntry.new(name:, options:, verb: cls.install_verb(name, options), cls:)
        end

        if (fetchable_names = fetchable_formulae_and_casks(installable_entries, no_upgrade:).presence)
          fetchable_names_joined = fetchable_names.join(", ")
          puts Formatter.success("Fetching #{fetchable_names_joined}") unless quiet
          unless Bundle.brew("fetch", *fetchable_names, verbose:)
            $stderr.puts Formatter.error "`brew bundle` failed! Failed to fetch #{fetchable_names_joined}"
            return false
          end
        end

        if jobs > 1
          formula_entries, other_entries = installable_entries.partition { |entry| entry.cls == Homebrew::Bundle::Brew }

          if formula_entries.size > 1
            formula_success, formula_failure = parallel_install_formulae!(
              formula_entries, jobs:, no_upgrade:, verbose:, force:, quiet:,
            )
            success += formula_success
            failure += formula_failure
          else
            formula_entries.each do |entry|
              if install_entry!(entry, no_upgrade:, verbose:, force:, quiet:)
                success += 1
              else
                failure += 1
              end
            end
          end

          other_entries.each do |entry|
            if install_entry!(entry, no_upgrade:, verbose:, force:, quiet:)
              success += 1
            else
              failure += 1
            end
          end
        else
          installable_entries.each do |entry|
            if install_entry!(entry, no_upgrade:, verbose:, force:, quiet:)
              success += 1
            else
              failure += 1
            end
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
        entries.filter_map do |entry|
          entry.cls.fetchable_name(entry.name, entry.options, no_upgrade:)
        end
      end

      sig {
        params(
          entry:        InstallableEntry,
          no_upgrade:   T::Boolean,
          verbose:      T::Boolean,
          force:        T::Boolean,
          quiet:        T::Boolean,
          output_mutex: T.nilable(Mutex),
        ).returns(T::Boolean)
      }
      def self.install_entry!(entry, no_upgrade:, verbose:, force:, quiet:, output_mutex: nil)
        name = entry.name
        options = entry.options
        verb = entry.verb
        cls = entry.cls

        preinstall = if cls.preinstall!(name, **options, no_upgrade:, verbose:)
          with_output_lock(output_mutex) { puts Formatter.success("#{verb} #{name}") }
          true
        else
          with_output_lock(output_mutex) { puts "Using #{name}" } unless quiet
          false
        end

        if cls.install!(name, **options,
                        preinstall:, no_upgrade:, verbose:, force:)
          true
        else
          with_output_lock(output_mutex) { $stderr.puts Formatter.error("#{verb} #{name} has failed!") }
          false
        end
      end

      sig {
        params(
          entries:     T::Array[InstallableEntry],
          jobs:        Integer,
          no_upgrade:  T::Boolean,
          verbose:     T::Boolean,
          force:       T::Boolean,
          quiet:       T::Boolean,
        ).returns([Integer, Integer])
      }
      def self.parallel_install_formulae!(entries, jobs:, no_upgrade:, verbose:, force:, quiet:)
        dependency_map = T.let({}, T::Hash[String, T::Set[String]])
        entry_name_map = T.let({}, T::Hash[String, String])

        entries.each do |entry|
          entry_name_map[entry.name] = entry.name
          entry_name_map[T.must(entry.name.split("/").last)] = entry.name
        end

        entries.each do |entry|
          formula = Homebrew::Bundle::Brew.formulae_by_full_name(entry.name)
          formula = Homebrew::Bundle::Brew.formulae_by_name(entry.name) if formula.blank?
          dependencies = T.cast(formula.fetch(:dependencies, []), T::Array[String])
          dependency_map[entry.name] = dependencies.each_with_object(Set.new) do |dependency, pending|
            dependency_name = entry_name_map[dependency] || entry_name_map[T.must(dependency.split("/").last)]
            pending << dependency_name if dependency_name.present? && dependency_name != entry.name
          end
        end

        success = 0
        failure = 0
        completed = T.let(Set.new, T::Set[String])
        mutex = T.let(Mutex.new, Mutex)
        output_mutex = T.let(Mutex.new, Mutex)
        pending_entries = entries.dup

        until pending_entries.empty?
          completed_names = mutex.synchronize { completed.dup }
          ready_entries = pending_entries.select do |entry|
            dependency_map.fetch(entry.name, Set.new).all? { |dependency| completed_names.include?(dependency) }
          end

          if ready_entries.empty?
            pending_entries.each do |entry|
              if install_entry!(entry, no_upgrade:, verbose:, force:, quiet:, output_mutex:)
                success += 1
              else
                failure += 1
              end
            end
            break
          end

          batch = ready_entries.take(jobs)
          thread_results = T.let({}, T::Hash[String, T::Boolean])

          threads = batch.map do |entry|
            Thread.new do
              installer = Homebrew::Bundle::Brew.new(entry.name, entry.options)

              preinstall = if installer.preinstall!(no_upgrade:, verbose:)
                output_mutex.synchronize { puts Formatter.success("#{entry.verb} #{entry.name}") }
                true
              else
                output_mutex.synchronize { puts "Using #{entry.name}" } unless quiet
                false
              end

              installed = if installer.install!(preinstall:, no_upgrade:, verbose:, force:)
                true
              else
                output_mutex.synchronize { $stderr.puts Formatter.error("#{entry.verb} #{entry.name} has failed!") }
                false
              end

              mutex.synchronize do
                thread_results[entry.name] = installed
                completed << entry.name
              end
            end
          end
          threads.each(&:join)

          batch.each do |entry|
            pending_entries.delete(entry)
            if thread_results.fetch(entry.name)
              success += 1
            else
              failure += 1
            end
          end
        end

        [success, failure]
      end

      sig { params(output_mutex: T.nilable(Mutex), block: T.proc.void).void }
      def self.with_output_lock(output_mutex, &block)
        if output_mutex.nil?
          yield
        else
          output_mutex.synchronize { yield }
        end
      end
      private_class_method :with_output_lock
      private_class_method :install_entry!
      private_class_method :parallel_install_formulae!
    end
  end
end
