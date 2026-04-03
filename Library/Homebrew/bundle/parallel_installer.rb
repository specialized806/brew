# typed: strict
# frozen_string_literal: true

require "concurrent/executors"
require "concurrent/promises"
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
        dependency_map = build_dependency_map

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
              installed = install_entry!(entry)
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
              install_entry!(install_entry)
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

      sig { returns(T::Hash[String, T::Set[String]]) }
      def build_dependency_map
        entry_name_map = @entries.each_with_object({}) do |entry, map|
          map[entry.name] = entry.name
          map[normalize_formula_name(entry.name)] = entry.name
        end

        @entries.each_with_object({}) do |entry, map|
          dependency_names = if entry.cls == Homebrew::Bundle::Brew
            formula = Homebrew::Bundle::Brew.formulae_by_full_name(entry.name)
            formula = Homebrew::Bundle::Brew.formulae_by_name(entry.name) if formula.blank?
            T.cast(formula.fetch(:dependencies, []), T::Array[String])
          else
            []
          end

          mapped_dependencies = dependency_names.each_with_object(Set.new) do |dependency, pending|
            dependency_name = entry_name_map[dependency] || entry_name_map[normalize_formula_name(dependency)]
            pending << dependency_name if dependency_name.present? && dependency_name != entry.name
          end
          map[entry.name] = mapped_dependencies
        end
      end

      sig { params(name: String).returns(String) }
      def normalize_formula_name(name)
        T.must(name.split("/").last)
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
