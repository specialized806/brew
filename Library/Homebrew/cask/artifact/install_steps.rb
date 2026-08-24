# typed: strict
# frozen_string_literal: true

require "cask/artifact/abstract_artifact"
require "install_steps"
require "keg"

module Cask
  module Artifact
    # Abstract superclass for install steps artifacts.
    class AbstractInstallSteps < AbstractArtifact
      abstract!

      sig { params(cask: Cask, steps: Homebrew::InstallSteps::Steps).void }
      def initialize(cask, steps)
        super
        @steps = T.let(Homebrew::InstallSteps::DSL.normalise_steps(steps), Homebrew::InstallSteps::Steps)
      end

      sig { returns(Homebrew::InstallSteps::Steps) }
      attr_reader :steps

      sig { override.returns(T::Array[T.anything]) }
      def to_args = [{ steps: }]

      sig { override.returns(String) }
      def summarize
        ::Utils.pluralize("install step", steps.length, include_count: true)
      end

      private

      sig { params(command: T.class_of(SystemCommand), phase: Symbol).void }
      def run_steps(command, phase: :install)
        runner = Homebrew::InstallSteps::Runner.new(context: cask, command:)
        sandbox = cask_sandbox(network_access_allowed: steps.any? do |step|
          step["type"] == "run" && step["network_access"] == true
        end)
        unless sandbox
          runner.run(steps, phase:)
          return
        end

        sandbox.allow_write_path cask.caskroom_path
        sandbox.allow_write_path cask.config.appdir
        Keg.keg_link_directories.each { |directory| sandbox.allow_write_path HOMEBREW_PREFIX/directory }
        original_home = Pathname(Dir.home).expand_path
        runner.sandbox_write_paths(steps, phase:).each do |path|
          sandbox.allow_write_path path
          sandbox.allow_read(path:, type: :subpath) if path.expand_path.ascend.include?(original_home)
        end
        payload = {
          "action"  => "install_steps",
          "context" => {
            "name"          => cask.name,
            "token"         => cask.token,
            "version"       => cask.version.to_s,
            "staged_path"   => cask.staged_path.to_s,
            "caskroom_path" => cask.caskroom_path.to_s,
            "home"          => Dir.home,
            "config"        => cask.config.to_json,
          },
          "phase"   => phase.to_s,
          "steps"   => steps,
        }
        unless runner.sudo_required?(steps)
          run_cask_sandbox(sandbox, payload)
          return
        end

        normalised_steps = Homebrew::InstallSteps::DSL.normalise_steps(steps)
        parent_error = T.let(nil, T.nilable(Exception))
        last_privileged_index = T.let(-1, Integer)
        # macOS caches sudo credentials per terminal or session, so privileged
        # steps must run in this parent process to reuse its ticket instead of
        # prompting once per sandbox child PTY. The child only nominates
        # predeclared steps by index; each request is fully validated here
        # because the sandboxed child is untrusted while running cask code.
        child_message_handler = proc do |message|
          response = Homebrew::InstallSteps::Runner::PRIVILEGED_STEP_FAILED
          begin
            request = begin
              JSON.parse(message)
            rescue JSON::ParserError
              nil
            end
            # Child error reports arrive on the same pipe; leave them for
            # `Utils.safe_fork` to raise.
            next if request.is_a?(Hash) && request.key?("json_class")
            next response if parent_error

            if !request.is_a?(Hash) ||
               request["type"] != Homebrew::InstallSteps::Runner::PRIVILEGED_STEP_REQUEST
              raise ArgumentError, "Invalid privileged cask child message."
            end

            index = request.fetch("index")
            unless index.is_a?(Integer)
              raise ArgumentError,
                    "Invalid privileged cask install step index: #{index.inspect}"
            end
            if index <= last_privileged_index
              raise ArgumentError, "Privileged cask install steps must be requested in order."
            end

            step = normalised_steps.fetch(index)
            unless runner.sudo_required?([step])
              raise ArgumentError, "Cask install step #{index} is not privileged."
            end

            # Guards are re-evaluated here instead of trusting the child, and
            # guard results persist across requests so multi-step guard blocks
            # keep the snapshot semantics of a single uninterrupted run.
            runner.run([step], phase:, reset_guard_results: false)
            last_privileged_index = index
            response = Homebrew::InstallSteps::Runner::PRIVILEGED_STEP_SUCCEEDED
          rescue Interrupt, StandardError => e
            parent_error ||= e
          end
          response
        end

        sandbox_error = T.let(nil, T.nilable(Exception))
        begin
          # Keep the parent terminal free for the sudo prompt: forwarded
          # sandbox stdin would otherwise compete for the password input.
          run_cask_sandbox(
            sandbox,
            payload,
            passthrough_stdin:     false,
            child_message_handler:,
          )
        rescue Interrupt, StandardError => e
          sandbox_error = e
        end

        raise parent_error if parent_error
        raise sandbox_error if sandbox_error
      end
    end

    # Artifact corresponding to the `preflight_steps` stanza.
    class PreflightSteps < AbstractInstallSteps
      sig { params(command: T.class_of(SystemCommand), _options: T.anything).void }
      def install_phase(command: SystemCommand, **_options)
        run_steps(command)
      end

      sig { params(command: T.class_of(SystemCommand), _options: T.anything).void }
      def uninstall_phase(command: SystemCommand, **_options)
        run_steps(command, phase: :uninstall)
      end
    end

    # Artifact corresponding to the `postflight_steps` stanza.
    class PostflightSteps < AbstractInstallSteps
      sig { params(command: T.class_of(SystemCommand), _options: T.anything).void }
      def install_phase(command: SystemCommand, **_options)
        run_steps(command)
      end

      sig { params(command: T.class_of(SystemCommand), _options: T.anything).void }
      def uninstall_phase(command: SystemCommand, **_options)
        run_steps(command, phase: :uninstall)
      end
    end

    # Artifact corresponding to the `uninstall_preflight_steps` stanza.
    class UninstallPreflightSteps < AbstractInstallSteps
      sig { params(command: T.class_of(SystemCommand), _options: T.anything).void }
      def uninstall_phase(command: SystemCommand, **_options)
        run_steps(command)
      end
    end

    # Artifact corresponding to the `uninstall_postflight_steps` stanza.
    class UninstallPostflightSteps < AbstractInstallSteps
      sig { params(command: T.class_of(SystemCommand), _options: T.anything).void }
      def uninstall_phase(command: SystemCommand, **_options)
        run_steps(command)
      end
    end
  end
end
