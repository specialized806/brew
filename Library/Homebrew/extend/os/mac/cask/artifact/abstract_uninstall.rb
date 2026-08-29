# typed: strict
# frozen_string_literal: true

require "cask/macos"
require "os/mac/ffi"

module OS
  module Mac
    module Cask
      module Artifact
        module AbstractUninstall
          extend T::Helpers

          requires_ancestor { ::Cask::Artifact::AbstractUninstall }

          sig { params(target: ::Pathname).returns(T::Boolean) }
          def undeletable?(target)
            MacOS.undeletable?(target)
          end

          module ClassMethods
            # The ancestry of the `brew` process cannot change while it runs, so the
            # lookup is shared by every artifact of every cask in the same invocation.
            sig { returns(T::Array[String]) }
            def ancestor_bundle_ids
              @ancestor_bundle_ids ||= T.let(begin
                pids = [Process.pid]
                while (ppid = MacOS::FFI::LibProc.parent_pid(pids.last)) && ppid > 1 && pids.exclude?(ppid)
                  pids << ppid
                end

                pids.filter_map { |pid| MacOS::FFI::AppKit.bundle_identifier_for_pid(pid) }
              end, T.nilable(T::Array[String]))
            end
          end
        end
      end
    end
  end
end

Cask::Artifact::AbstractUninstall.prepend(OS::Mac::Cask::Artifact::AbstractUninstall)
Cask::Artifact::AbstractUninstall.singleton_class.prepend(OS::Mac::Cask::Artifact::AbstractUninstall::ClassMethods)
