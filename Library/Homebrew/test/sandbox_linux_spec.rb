# typed: false
# frozen_string_literal: true

require "sandbox"
require "extend/os/linux/sandbox" if OS.linux?

RSpec.describe Sandbox, :needs_linux do
  subject(:sandbox) { described_class.new }

  around do |example|
    with_env(HOMEBREW_SANDBOX_LINUX: "1") { example.run }
  end

  describe "::bubblewrap_executable" do
    let(:sandbox_class) do
      Class.new(described_class) do
        class << self
          attr_accessor :test_executable_candidate_paths

          def executable_candidate_paths = test_executable_candidate_paths
        end
      end
    end
    let(:setuid_dir) { mktmpdir }
    let(:usable_dir) { mktmpdir }
    let(:setuid_bubblewrap) { setuid_dir/"bwrap" }
    let(:usable_bubblewrap) { usable_dir/"bwrap" }

    before do
      FileUtils.touch setuid_bubblewrap
      FileUtils.chmod "+x", setuid_bubblewrap
      FileUtils.touch usable_bubblewrap
      FileUtils.chmod "+x", usable_bubblewrap
      sandbox_class.test_executable_candidate_paths = PATH.new(setuid_dir, usable_dir)
      allow(File).to receive(:stat).and_call_original
      allow(File).to receive(:stat).with(setuid_bubblewrap).and_return(instance_double(File::Stat, setuid?: true))
    end

    it "skips setuid bubblewrap candidates" do
      expect(sandbox_class.bubblewrap_executable).to eq(usable_bubblewrap)
    end

    it "raises when no suitable bubblewrap candidate exists" do
      sandbox_class.test_executable_candidate_paths = PATH.new(mktmpdir)

      expect { sandbox_class.bubblewrap_executable! }
        .to raise_error(RuntimeError, "Bubblewrap is required to use the Linux sandbox.")
    end
  end

  describe "::available?" do
    let(:sandbox_class) do
      Class.new(described_class) do
        class << self
          attr_accessor :test_executable

          def executable = test_executable
        end
      end
    end
    let(:bubblewrap_dir) { mktmpdir }
    let(:bubblewrap) { bubblewrap_dir/"bwrap" }

    before do
      FileUtils.touch bubblewrap
      FileUtils.chmod "+x", bubblewrap
      sandbox_class.test_executable = bubblewrap
    end

    it "returns false unless Linux sandboxing is enabled" do
      with_env(HOMEBREW_SANDBOX_LINUX: nil) do
        expect(sandbox_class.available?).to be(false)
      end
    end

    it "returns false when bubblewrap is unavailable" do
      sandbox_class.test_executable = nil

      expect(sandbox_class.available?).to be(false)
    end

    it "probes unprivileged namespace support" do
      expect(sandbox_class).to receive(:system).with(
        bubblewrap.to_s,
        "--unshare-user",
        "--unshare-ipc",
        "--unshare-pid",
        "--unshare-uts",
        "--unshare-cgroup-try",
        "--ro-bind", "/", "/",
        "--proc", "/proc",
        "--dev", "/dev",
        "true",
        out: File::NULL,
        err: File::NULL
      ).and_return(true)

      expect(sandbox_class.available?).to be(true)
    end
  end

  describe "#bubblewrap_args" do
    let(:dir) { mktmpdir }
    let(:denied_dir) { mktmpdir }
    let(:tmpdir) { mktmpdir }
    let(:args) { sandbox.send(:bubblewrap_args, tmpdir.to_s) }

    it "maps allowed and denied writes to bind mounts" do
      sandbox.allow_write_path dir
      sandbox.deny_write_path denied_dir
      sandbox.deny_all_network

      expect(args).to include("--unshare-user", "--unshare-ipc", "--unshare-pid", "--unshare-net", "--new-session")
      expect(args.each_cons(3)).to include(["--bind", dir.to_s, dir.to_s])
      expect(args.each_cons(3)).to include(["--ro-bind", denied_dir.to_s, denied_dir.to_s])
    end

    it "runs from the sandbox tmpdir" do
      expect(args.each_cons(3)).to include(["--bind", tmpdir.to_s, tmpdir.to_s])
      expect(args.each_cons(2)).to include(["--chdir", tmpdir.to_s])
    end

    it "exposes the Homebrew library path" do
      expect(args.index(HOMEBREW_LIBRARY_PATH.dirname.to_s)).to be < args.index(HOMEBREW_LIBRARY_PATH.to_s)
      expect(args.each_cons(3)).to include(["--ro-bind", HOMEBREW_LIBRARY_PATH.to_s, HOMEBREW_LIBRARY_PATH.to_s])
    end

    it "exposes Linux runtime paths" do
      %w[/run /sys].select { |path| File.exist?(path) }.each do |path|
        expect(args.each_cons(3)).to include(["--ro-bind", path, path])
      end
    end

    it "maps allowed reads to read-only bind mounts" do
      file = mktmpdir/"foo.rb"
      FileUtils.touch file
      sandbox.allow_read path: file

      expect(args.each_cons(3)).to include(["--ro-bind", file.to_s, file.to_s])
    end

    it "uses Linux temp paths instead of macOS temp paths" do
      sandbox.allow_write_temp_and_cache

      expect(args).to include("/tmp", "/var/tmp", HOMEBREW_TEMP.to_s, HOMEBREW_CACHE.to_s)
      expect(args).not_to include("/private/tmp", "/private/var/tmp")
    end

    it "does not add Xcode write paths" do
      sandbox.allow_write_xcode

      expect(sandbox.send(:writable_paths)).to be_empty
    end

    it "rejects regex path filters" do
      sandbox.allow_write path: "^/tmp/homebrew-[^/]+$", type: :regex

      expect { args }.to raise_error(ArgumentError, /Linux sandbox does not support regex path filters/)
    end
  end

  describe "#run" do
    before do
      skip "Sandbox not implemented." if !ENV["CI"] && !described_class.available?
    end

    it "allows writing to an allowed path" do
      file = mktmpdir/"foo"
      sandbox.allow_write path: file
      sandbox.run "touch", file

      expect(file).to exist
    end

    it "fails when writing to a path that has not been allowed" do
      file = mktmpdir/"foo"

      expect do
        sandbox.run "touch", file
      end.to raise_error(ErrorDuringExecution)

      expect(file).not_to exist
    end

    it "returns the command exit status" do
      expect { sandbox.run "false" }.to raise_error(ErrorDuringExecution)
    end
  end
end
