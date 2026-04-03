# typed: strict
# frozen_string_literal: true

require "concurrent/executors"
require "concurrent/promises"
require "lock_file"
require "bundle/package_types"

module Homebrew
  module Bundle
    class ParallelInstaller
      sig {
        params(
          entries:    T::Array[Installer::InstallableEntry],
          jobs:       Integer,
          no_upgrade: T::Boolean,
          verbose:    T::Boolean,
          force:      T::Boolean,
          quiet:      T::Boolean,
        ).void
      }
      def initialize(entries, jobs:, no_upgrade:, verbose:, force:, quiet:)
        @entries = entries
        @jobs = jobs
        @no_upgrade = no_upgrade
        @verbose = verbose
        @force = force
        @quiet = quiet
        @pool = T.let(Concurrent::FixedThreadPool.new(jobs), Concurrent::FixedThreadPool)
        @output_mutex = T.let(Mutex.new, Mutex)
      end

      sig { returns([Integer, Integer]) }
      def run!
        dependency_names = build_dependency_names
        dependency_map = build_dependency_map(dependency_names)
        lock_names = build_lock_names(dependency_names)

        success = 0
        failure = 0
        pending_entries = T.let(@entries.dup, T::Array[Installer::InstallableEntry])
        completed = T.let(Set.new, T::Set[String])

        until pending_entries.empty?
          ready_entries = pending_entries.select do |entry|
            dependency_map.fetch(entry.name, Set.new).all? { |dependency| completed.include?(dependency) }
          end

          if ready_entries.empty?
            pending_entries.each do |entry|
              installed = install_with_locks!(entry, lock_names.fetch(entry.name, []))
              completed << entry.name
              if installed
                success += 1
              else
                failure += 1
              end
            end
            break
          end

          batch = ready_entries.take(@jobs)
          futures = batch.to_h do |entry|
            [entry, Concurrent::Promises.future_on(@pool, entry) do |install_entry|
              install_with_locks!(install_entry, lock_names.fetch(install_entry.name, []))
            end]
          end

          batch.each do |entry|
            installed = begin
              T.cast(futures.fetch(entry).value!, T::Boolean)
            rescue => e
              write_output(Formatter.error("Installing #{entry.name} has failed!"), stream: $stderr)
              write_output("[#{entry.name}] #{e.message}", stream: $stderr) if @verbose
              false
            end

            pending_entries.delete(entry)
            completed << entry.name
            if installed
              success += 1
            else
              failure += 1
            end
          end
        end

        [success, failure]
      ensure
        @pool.shutdown
        @pool.wait_for_termination
      end

      private

      sig { returns(T::Hash[String, T::Array[String]]) }
      def build_dependency_names
        @entries.each_with_object({}) do |entry, map|
          formula = Homebrew::Bundle::Brew.formulae_by_full_name(entry.name)
          formula = Homebrew::Bundle::Brew.formulae_by_name(entry.name) if formula.blank?
          dependencies = T.cast(formula.fetch(:dependencies, []), T::Array[String])
          map[entry.name] = dependencies
        end
      end

      sig { params(dependency_names: T::Hash[String, T::Array[String]]).returns(T::Hash[String, T::Set[String]]) }
      def build_dependency_map(dependency_names)
        entry_name_map = @entries.each_with_object({}) do |entry, map|
          map[entry.name] = entry.name
          map[normalize_formula_name(entry.name)] = entry.name
        end

        @entries.each_with_object({}) do |entry, map|
          mapped_dependencies = dependency_names.fetch(entry.name,
                                                       []).each_with_object(Set.new) do |dependency, pending|
            dependency_name = entry_name_map[dependency] || entry_name_map[normalize_formula_name(dependency)]
            pending << dependency_name if dependency_name.present? && dependency_name != entry.name
          end
          map[entry.name] = mapped_dependencies
        end
      end

      sig { params(dependency_names: T::Hash[String, T::Array[String]]).returns(T::Hash[String, T::Array[String]]) }
      def build_lock_names(dependency_names)
        dependency_counts = T.let(Hash.new(0), T::Hash[String, Integer])
        dependency_names.each_value do |dependencies|
          dependencies.map { |dependency| normalize_formula_name(dependency) }.uniq.each do |dependency|
            dependency_counts[dependency] = T.must(dependency_counts[dependency]) + 1
          end
        end

        shared_dependencies = dependency_counts.each_with_object(Set.new) do |(dependency, count), dependencies|
          dependencies << dependency if count > 1
        end

        @entries.to_h do |entry|
          [entry.name, dependency_names.fetch(entry.name, [])
                                       .map { |dependency| normalize_formula_name(dependency) }
                                       .uniq
                                       .select { |dependency| shared_dependencies.include?(dependency) }
                                       .sort]
        end
      end

      sig { params(name: String).returns(String) }
      def normalize_formula_name(name)
        T.must(name.split("/").last)
      end

      sig { params(entry: Installer::InstallableEntry, lock_names: T::Array[String]).returns(T::Boolean) }
      def install_with_locks!(entry, lock_names)
        with_formula_locks(lock_names) do
          install_entry!(entry)
        end
      end

      sig { params(lock_names: T::Array[String], block: T.proc.returns(T::Boolean)).returns(T::Boolean) }
      def with_formula_locks(lock_names, &block)
        locks = lock_names.map { |lock_name| FormulaLock.new(lock_name) }
        with_acquired_locks(locks, &block)
      end

      sig { params(locks: T::Array[FormulaLock], block: T.proc.returns(T::Boolean)).returns(T::Boolean) }
      def with_acquired_locks(locks, &block)
        return yield if locks.empty?

        lock = T.must(locks.first)
        acquire_lock(lock)
        with_acquired_locks(locks.drop(1), &block)
      ensure
        lock&.unlock
      end

      sig { params(lock: FormulaLock).void }
      def acquire_lock(lock)
        loop do
          lock.lock
          break
        rescue OperationInProgressError
          sleep 0.05
        end
      end

      sig { params(entry: Installer::InstallableEntry).returns(T::Boolean) }
      def install_entry!(entry)
        name = entry.name
        options = entry.options
        verb = entry.verb
        cls = entry.cls

        preinstall = if cls.preinstall!(name, **options, no_upgrade: @no_upgrade, verbose: @verbose)
          write_output(Formatter.success("#{verb} #{name}"))
          true
        else
          write_output("Using #{name}") unless @quiet
          false
        end

        if cls.install!(name, **options,
                        preinstall:, no_upgrade: @no_upgrade, verbose: @verbose, force: @force)
          true
        else
          write_output(Formatter.error("#{verb} #{name} has failed!"), stream: $stderr)
          false
        end
      end

      sig { params(message: String, stream: IO).void }
      def write_output(message, stream: $stdout)
        @output_mutex.synchronize { stream.puts(message) }
      end
    end
  end
end
