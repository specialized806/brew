# typed: strict
# frozen_string_literal: true

require "os/mac/ffi/native_library"

module OS
  module Mac
    module FFI
      # libproc wrapper
      module LibProc
        extend NativeLibrary

        use_library "/usr/lib/libproc.dylib"

        # sys/proc_info.h:
        #   #define PROC_PIDTBSDINFO 3
        PROC_PIDTBSDINFO = 3

        # sys/proc_info.h:
        #   struct proc_bsdinfo { uint32_t pbi_flags, pbi_status, pbi_xstatus, pbi_pid, pbi_ppid; ... };
        PROC_BSDINFO_SIZE = 136
        PROC_BSDINFO_PPID_OFFSET = 16
        private_constant :PROC_BSDINFO_SIZE, :PROC_BSDINFO_PPID_OFFSET

        # libproc.h:
        #   int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
        #
        # Returns `nil` if the process does not exist or cannot be inspected.
        sig { params(pid: Integer).returns(T.nilable(Integer)) }
        def self.parent_pid(pid)
          buffer = Fiddle::Pointer.malloc(PROC_BSDINFO_SIZE, Fiddle::RUBY_FREE)
          size = function(
            "proc_pidinfo",
            [Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_UINT64_T, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
            Fiddle::TYPE_INT,
          ).call(pid, PROC_PIDTBSDINFO, 0, buffer, PROC_BSDINFO_SIZE)
          return if size != PROC_BSDINFO_SIZE

          buffer[PROC_BSDINFO_PPID_OFFSET, 4].unpack1("L")
        end
      end
    end
  end
end
