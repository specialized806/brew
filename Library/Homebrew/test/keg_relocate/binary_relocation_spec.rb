# typed: true
# frozen_string_literal: true

require "keg_relocate"

RSpec.describe Keg do
  subject(:keg) { described_class.new(HOMEBREW_CELLAR/"foo/1.0.0") }

  let(:dir) { HOMEBREW_CELLAR/"foo/1.0.0" }
  let(:newdir) { HOMEBREW_CELLAR/"foo" }
  let(:binary_file) { dir/"file.bin" }

  before do
    dir.mkpath
  end

  def setup_binary_file
    binary_file.atomic_write <<~EOS
      \x00#{dir}\x00
    EOS
  end

  describe "#relocate_build_prefix" do
    specify "replace prefix in binary files" do
      setup_binary_file

      keg.relocate_build_prefix(keg, dir, newdir)

      old_prefix_matches = Set.new
      keg.each_unique_file_matching(dir) do |file|
        old_prefix_matches << file
      end

      expect(old_prefix_matches.size).to eq 0

      new_prefix_matches = Set.new
      keg.each_unique_file_matching(newdir) do |file|
        new_prefix_matches << file
      end

      expect(new_prefix_matches.size).to eq 1
    end

    specify "replace prefix in recorded files without scanning the keg" do
      setup_binary_file

      expect(keg).not_to receive(:each_unique_file_matching)
      keg.relocate_build_prefix(keg, dir, newdir, files: [Pathname("file.bin")])

      null_padding = "\x00" * (dir.to_s.length - newdir.to_s.length)
      expect(binary_file.binread).to eq "\x00#{newdir}#{null_padding}\x00\n"
    end

    specify "does not rewrite recorded files without the old prefix" do
      binary_file.atomic_write "\x00unrelated\x00"
      inode = binary_file.stat.ino

      keg.relocate_build_prefix(keg, dir, newdir, files: [Pathname("file.bin")])

      expect(binary_file.stat.ino).to eq inode
    end
  end
end
