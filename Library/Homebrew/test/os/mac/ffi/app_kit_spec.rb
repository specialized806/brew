# typed: strict
# frozen_string_literal: true

require "os/mac/ffi/app_kit"

RSpec.describe MacOS::FFI::AppKit, :needs_macos do
  describe ".bundle_identifier_for_pid" do
    it "returns nil for a process that is not an application" do
      expect(described_class.bundle_identifier_for_pid(Process.pid)).to be_nil
    end

    it "returns nil for a process that does not exist" do
      expect(described_class.bundle_identifier_for_pid(-1)).to be_nil
    end
  end
end
