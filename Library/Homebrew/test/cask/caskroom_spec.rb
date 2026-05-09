# typed: false
# frozen_string_literal: true

require "cask/caskroom"

RSpec.describe Cask::Caskroom do
  before { described_class.instance_variable_set(:@expected_caskroom_group, nil) }

  describe ".ensure_caskroom_exists" do
    it "changes the group when sudo is unnecessary and the group is wrong" do
      Dir.mktmpdir do |dir|
        path = Pathname(dir)/"Caskroom"
        allow(described_class).to receive(:path).and_return(path)
        allow(described_class).to receive(:caskroom_group_correct?).with(path).and_return(false)
        expect(described_class).to receive(:chgrp_path).with(path, false)

        described_class.ensure_caskroom_exists
      end
    end

    it "skips changing the group when it is already correct" do
      Dir.mktmpdir do |dir|
        path = Pathname(dir)/"Caskroom"
        allow(described_class).to receive(:path).and_return(path)
        allow(described_class).to receive(:caskroom_group_correct?).with(path).and_return(true)
        expect(described_class).not_to receive(:chgrp_path)

        described_class.ensure_caskroom_exists
      end
    end

    it "changes the group with sudo when the parent is not writable and the group is wrong" do
      Dir.mktmpdir do |dir|
        path = Pathname(dir)/"sub"/"Caskroom"
        parent = path.parent
        allow(described_class).to receive_messages(path:, caskroom_group_correct?: false)
        allow(path).to receive(:parent).and_return(parent)
        allow(parent).to receive(:writable?).and_return(false)
        allow(SystemCommand).to receive(:run)

        expect(described_class).to receive(:chgrp_path).with(path, true)

        described_class.ensure_caskroom_exists
      end
    end

    it "skips changing the group when it is already correct and the parent is not writable" do
      Dir.mktmpdir do |dir|
        path = Pathname(dir)/"sub"/"Caskroom"
        parent = path.parent
        allow(described_class).to receive_messages(path:, caskroom_group_correct?: true)
        allow(path).to receive(:parent).and_return(parent)
        allow(parent).to receive(:writable?).and_return(false)
        allow(SystemCommand).to receive(:run)

        expect(described_class).not_to receive(:chgrp_path)

        described_class.ensure_caskroom_exists
      end
    end

    it "skips sudo on Linux when the parent is user-writable", :needs_linux do
      Dir.mktmpdir do |dir|
        path = Pathname(dir)/"Caskroom"
        allow(described_class).to receive(:path).and_return(path)
        expect(SystemCommand).not_to receive(:run).with(anything, hash_including(sudo: true))
        allow(SystemCommand).to receive(:run).and_call_original

        described_class.ensure_caskroom_exists

        expect(path).to be_directory
        expect(path.stat.gid).to eq(Process.egid)
      end
    end
  end

  describe ".caskroom_group_correct?" do
    it "checks the admin group on macOS", :needs_macos do
      path = Pathname("/tmp/Caskroom")
      allow(path).to receive(:stat).and_return(instance_double(File::Stat, gid: 1))
      allow(Etc).to receive(:getgrnam).with("admin").and_return(instance_double(Etc::Group, gid: 1))

      expect(described_class.caskroom_group_correct?(path)).to be true
    end

    it "checks the current user's primary group on Linux", :needs_linux do
      group_name = "primary-group"
      path = Pathname("/tmp/Caskroom")
      allow(path).to receive(:stat).and_return(instance_double(File::Stat, gid: 1))
      allow(Etc).to receive(:getgrgid).with(Process.egid).and_return(instance_double(Etc::Group, name: group_name))
      allow(Etc).to receive(:getgrnam).with(group_name).and_return(instance_double(Etc::Group, gid: 1))

      expect(described_class.caskroom_group_correct?(path)).to be true
    end

    it "returns false when the expected group is unavailable" do
      allow(described_class).to receive(:expected_caskroom_group).and_return("missing")
      allow(Etc).to receive(:getgrnam).with("missing").and_return(nil)

      expect(described_class.caskroom_group_correct?(Pathname("/tmp/Caskroom"))).to be false
    end
  end

  describe ".corrupt_cask_dirs" do
    it "returns tokens for directories without valid caskfiles" do
      Dir.mktmpdir do |dir|
        allow(described_class).to receive(:path).and_return(Pathname(dir))
        (Pathname(dir)/"corrupt-cask"/"1.0").mkpath
        casks_dir = (Pathname(dir)/"installed-cask"/".metadata"/"1.0"/"0"/"Casks")
        casks_dir.mkpath
        FileUtils.touch casks_dir/"installed-cask.rb"

        expect(described_class.corrupt_cask_dirs).to eq(["corrupt-cask"])
      end
    end

    it "returns empty array when all directories have valid caskfiles" do
      Dir.mktmpdir do |dir|
        allow(described_class).to receive(:path).and_return(Pathname(dir))
        casks_dir = (Pathname(dir)/"installed-cask"/".metadata"/"1.0"/"0"/"Casks")
        casks_dir.mkpath
        FileUtils.touch casks_dir/"installed-cask.rb"

        expect(described_class.corrupt_cask_dirs).to be_empty
      end
    end

    it "returns empty array when caskroom is empty" do
      Dir.mktmpdir do |dir|
        allow(described_class).to receive(:path).and_return(Pathname(dir))

        expect(described_class.corrupt_cask_dirs).to be_empty
      end
    end
  end
end
