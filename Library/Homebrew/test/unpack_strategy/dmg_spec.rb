# typed: true
# frozen_string_literal: true

require_relative "shared_examples"

RSpec.describe UnpackStrategy::Dmg, :needs_macos do
  describe ".can_extract?" do
    let(:path) { TEST_FIXTURE_DIR/"cask/container.dmg" }
    let(:status) { instance_double(Process::Status, success?: true) }
    let(:result) { instance_double(SystemCommand::Result, to_a: ["plist", "", status]) }

    before do
      allow(described_class).to receive(:system_command).and_return(result)
    end

    it "uses diskutil on the oldest supported macOS" do
      allow(MacOS).to receive(:version).and_return(MacOSVersion.from_symbol(:sonoma))
      expect(described_class).to receive(:system_command)
        .with("diskutil", args: ["image", "info", "--plist", "--", path], print_stderr: false)
        .and_return(result)

      expect(described_class.can_extract?(path)).to be true
    end

    it "uses hdiutil before macOS Sonoma" do
      allow(MacOS).to receive(:version).and_return(MacOSVersion.from_symbol(:ventura))
      expect(described_class).to receive(:system_command)
        .with("hdiutil", args: ["imageinfo", "-format", path], print_stderr: false)
        .and_return(result)

      expect(described_class.can_extract?(path)).to be true
    end

    it "detects a disk image when diskutil returns a license agreement" do
      allow(MacOS).to receive(:version).and_return(MacOSVersion.from_symbol(:sonoma))
      failure_status = instance_double(Process::Status, success?: false)
      diskutil_result = instance_double(SystemCommand::Result, to_a: ["license agreement", "", failure_status])

      expect(described_class).to receive(:system_command)
        .with("diskutil", args: ["image", "info", "--plist", "--", path], print_stderr: false)
        .and_return(diskutil_result)
      expect(described_class).not_to receive(:system_command).with("hdiutil", anything)

      expect(described_class.can_extract?(path)).to be true
    end

    it "rejects unexpected stdout from a failed diskutil image info" do
      allow(MacOS).to receive(:version).and_return(MacOSVersion.from_symbol(:sonoma))
      path = TEST_FIXTURE_DIR/"cask/container.xar"
      failure_status = instance_double(Process::Status, success?: false)
      diskutil_result = instance_double(SystemCommand::Result, to_a: ["unexpected output", "", failure_status])

      expect(described_class).to receive(:system_command)
        .with("diskutil", args: ["image", "info", "--plist", "--", path], print_stderr: false)
        .and_return(diskutil_result)
      expect(described_class).not_to receive(:system_command).with("hdiutil", anything)

      expect(described_class.can_extract?(path)).to be false
    end

    it "rejects files too small to contain a UDIF trailer" do
      allow(MacOS).to receive(:version).and_return(MacOSVersion.from_symbol(:sonoma))
      path = TEST_FIXTURE_DIR/"cask/container.tar.gz"
      failure_status = instance_double(Process::Status, success?: false)
      diskutil_result = instance_double(SystemCommand::Result, to_a: ["unexpected output", "", failure_status])

      expect(described_class).to receive(:system_command)
        .with("diskutil", args: ["image", "info", "--plist", "--", path], print_stderr: false)
        .and_return(diskutil_result)
      expect(described_class).not_to receive(:system_command).with("hdiutil", anything)

      expect(described_class.can_extract?(path)).to be false
    end
  end

  describe "#mount" do
    let(:path) { TEST_FIXTURE_DIR/"cask/container.dmg" }

    include_examples "UnpackStrategy::detect"

    specify "#extract" do
      Dir.mktmpdir do |dir|
        unpack_dir = Pathname(dir)
        # `Mount` is a private constant on the strategy under test.
        # rubocop:disable Sorbet/ConstantsFromStrings
        mount = instance_double(described_class.const_get(:Mount, false))
        # rubocop:enable Sorbet/ConstantsFromStrings
        unpack_strategy = described_class.new(path)

        allow(unpack_strategy).to receive(:mount).with(verbose: false).and_yield([mount])
        allow(mount).to receive(:extract).with(to: unpack_dir, verbose: false) do
          (unpack_dir/"container").mkpath
        end

        unpack_strategy.extract(to: unpack_dir)
        expect(unpack_dir.children(false).map(&:to_s)).to contain_exactly("container")
      end
    end

    it "does not treat an unrelated attach failure as a license agreement" do
      allow(MacOS).to receive(:version).and_return(MacOSVersion.from_symbol(:sonoma))
      unpack_strategy = described_class.new(path)
      attach_result = instance_double(SystemCommand::Result, success?: false, stdout: "")
      attach_error = ErrorDuringExecution.new(["diskutil", "image", "attach"], status: 1)

      allow(unpack_strategy).to receive(:system_command).and_return(attach_result)
      expect(attach_result).to receive(:assert_success!).and_raise(attach_error)
      expect(unpack_strategy).not_to receive(:system_command!)

      expect { unpack_strategy.mount { nil } }.to raise_error(attach_error)
    end

    it "uses an isolated diskutil mount point" do
      allow(MacOS).to receive(:version).and_return(MacOSVersion.from_symbol(:sonoma))
      attach_result = instance_double(
        SystemCommand::Result,
        success?: true,
        plist:    { "system-entities" => [] },
      )
      unpack_strategy = described_class.new(path)

      expect(unpack_strategy).to receive(:system_command).with(
        "diskutil",
        args:         [
          "image", "attach", "--plist", "--readOnly", "--mountOptions", "nobrowse",
          "--mountPoint", kind_of(Pathname), path
        ],
        input:        "qn\n",
        print_stderr: false,
        verbose:      false,
      ).and_return(attach_result)

      unpack_strategy.mount { |mounts| expect(mounts).to be_empty }
    end

    it "retries without a mount point for multi-volume disk images" do
      allow(MacOS).to receive(:version).and_return(MacOSVersion.from_symbol(:sonoma))
      mount_point_result = instance_double(SystemCommand::Result, success?: false, stdout: "")
      fallback_result = instance_double(
        SystemCommand::Result,
        success?: true,
        plist:    { "system-entities" => [] },
      )
      unpack_strategy = described_class.new(path)

      expect(unpack_strategy).to receive(:system_command).with(
        "diskutil",
        args:         [
          "image", "attach", "--plist", "--readOnly", "--mountOptions", "nobrowse",
          "--mountPoint", kind_of(Pathname), path
        ],
        input:        "qn\n",
        print_stderr: false,
        verbose:      false,
      ).ordered.and_return(mount_point_result)
      expect(unpack_strategy).to receive(:system_command).with(
        "diskutil",
        args:         ["image", "attach", "--plist", "--readOnly", "--mountOptions", "nobrowse", path],
        input:        "qn\n",
        print_stderr: false,
        verbose:      false,
      ).ordered.and_return(fallback_result)

      unpack_strategy.mount { |mounts| expect(mounts).to be_empty }
    end

    it "uses hdiutil before macOS Sonoma" do
      allow(MacOS).to receive(:version).and_return(MacOSVersion.from_symbol(:ventura))
      attach_result = instance_double(
        SystemCommand::Result,
        success?: true,
        plist:    { "system-entities" => [] },
      )
      unpack_strategy = described_class.new(path)

      expect(unpack_strategy).to receive(:system_command).with(
        "hdiutil",
        args:         [
          "attach", "-plist", "-nobrowse", "-readonly",
          "-mountrandom", kind_of(Pathname), path
        ],
        input:        "qn\n",
        print_stderr: false,
        verbose:      false,
      ).and_return(attach_result)

      unpack_strategy.mount { |mounts| expect(mounts).to be_empty }
    end

    it "converts disk images with license agreements using diskutil" do
      allow(MacOS).to receive(:version).and_return(MacOSVersion.from_symbol(:sonoma))
      eula_result = instance_double(SystemCommand::Result, success?: false, stdout: "license agreement")
      converted_result = instance_double(
        SystemCommand::Result,
        success?:        true,
        assert_success!: nil,
        plist:           { "system-entities" => [] },
      )
      unpack_strategy = described_class.new(path)

      allow(unpack_strategy).to receive(:system_command).and_return(eula_result, converted_result)
      expect(unpack_strategy).to receive(:system_command!).with(
        "diskutil",
        args:         [
          "image", "create", "from", "--format", "RAW", path,
          satisfy { |output| output.is_a?(Pathname) && output.extname == ".dmg" }
        ],
        print_stderr: false,
        verbose:      false,
      ).and_return(instance_double(SystemCommand::Result))

      unpack_strategy.mount { |mounts| expect(mounts).to be_empty }
    end

    it "converts disk images with license agreements using hdiutil before macOS Sonoma" do
      allow(MacOS).to receive(:version).and_return(MacOSVersion.from_symbol(:ventura))
      eula_result = instance_double(SystemCommand::Result, success?: false, stdout: "license agreement")
      converted_result = instance_double(
        SystemCommand::Result,
        success?:        true,
        assert_success!: nil,
        plist:           { "system-entities" => [] },
      )
      unpack_strategy = described_class.new(path)

      allow(unpack_strategy).to receive(:system_command).and_return(eula_result, converted_result)
      expect(unpack_strategy).to receive(:system_command!).with(
        "hdiutil",
        args:    [
          "convert", "-quiet", "-format", "UDTO", "-o",
          satisfy { |output| output.is_a?(Pathname) && output.extname == ".cdr" }, path
        ],
        verbose: false,
      ).and_return(instance_double(SystemCommand::Result))

      unpack_strategy.mount { |mounts| expect(mounts).to be_empty }
    end
  end
end
