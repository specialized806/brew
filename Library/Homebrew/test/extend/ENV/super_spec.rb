# typed: strict
# frozen_string_literal: true

require "compilers"
require "extend/ENV/super"

RSpec.describe Superenv do
  before { ENV.extend(described_class) }

  context "when using versioned GCC" do
    sig { returns(String) }
    let(:gcc) { "gcc-#{CompilerConstants::GNU_GCC_VERSIONS.last}" }

    before { ENV.method(gcc).call }

    it "sets versioned HOMEBREW_CC" do
      expect(ENV.fetch("HOMEBREW_CC", nil)).to eq gcc
    end

    it "sets unversioned CC/CXX on Linux", :needs_linux do
      expect(ENV.fetch("CC", nil)).to eq "gcc"
      expect(ENV.fetch("CXX", nil)).to eq "g++"
      expect(ENV.fetch("OBJC", nil)).to eq "gcc"
      expect(ENV.fetch("OBJCXX", nil)).to eq "g++"
    end

    # We keep versioned name on macOS as /usr/bin/gcc is Clang which may not
    # be compatible with binaries created with GCC, e.g. if using libstdc++.
    it "sets versioned CC/CXX on macOS", :needs_macos do
      expect(ENV.fetch("CC", nil)).to eq gcc
      expect(ENV.fetch("CXX", nil)).to eq gcc.sub("gcc", "g++")
      expect(ENV.fetch("OBJC", nil)).to eq gcc
      expect(ENV.fetch("OBJCXX", nil)).to eq gcc.sub("gcc", "g++")
    end
  end
end
