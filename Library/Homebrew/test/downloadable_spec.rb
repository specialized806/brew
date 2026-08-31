# typed: true
# frozen_string_literal: true

require "downloadable"

RSpec.describe Downloadable::VerificationCache do
  subject(:cache) { described_class.new }

  let(:file) { HOMEBREW_CACHE/"downloads/digest-cache-test.tar.gz" }
  let(:checksum) { Checksum.new(Digest::SHA256.hexdigest("contents")) }

  before do
    file.dirname.mkpath
    file.write("contents")
  end

  it "hashes an unchanged file at most once across verifications and digest reads" do
    expect(Digest::SHA256).to receive(:file).once.and_call_original

    cache.verify(file, checksum)
    cache.verify(file, checksum)
    expect(cache.sha256(file)).to eq(checksum.hexdigest)
  end

  it "hashes a file again when its contents change on disk" do
    cache.sha256(file)
    file.write("changed contents")

    expect(cache.sha256(file)).to eq(Digest::SHA256.hexdigest("changed contents"))
  end

  it "hashes a replacement file again despite an identical size and restored modification time" do
    modification_time = Time.utc(2026, 1, 1)
    File.utime(modification_time, modification_time, file)
    cache.sha256(file)
    replacement = file.dirname/"replacement.tar.gz"
    replacement.write("CONTENTS")
    File.utime(modification_time, modification_time, replacement)
    FileUtils.mv(replacement, file)

    expect(cache.sha256(file)).to eq(Digest::SHA256.hexdigest("CONTENTS"))
  end

  it "raises for a checksum mismatch without rehashing the unchanged file" do
    bad_checksum = Checksum.new("bad0" * 16)
    expect(Digest::SHA256).to receive(:file).once.and_call_original

    2.times do
      expect { cache.verify(file, bad_checksum) }.to raise_error(ChecksumMismatchError) do |error|
        expect(error.actual).to eq(checksum)
      end
    end
  end
end
