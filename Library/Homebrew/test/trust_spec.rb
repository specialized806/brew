# typed: false
# frozen_string_literal: true

require "tap"
require "trust"

RSpec.describe Homebrew::Trust do
  it "is enabled by HOMEBREW_REQUIRE_TAP_TRUST" do
    with_env(HOMEBREW_REQUIRE_TAP_TRUST: "1") do
      expect(Homebrew::Trust).to be_enabled
    end
  end

  it "trusts third-party taps" do
    tap = Tap.fetch("thirdparty", "foo")

    expect(Homebrew::Trust.trusted_tap?(tap)).to be(false)

    Homebrew::Trust.trust!(:tap, "thirdparty/foo")

    expect(Homebrew::Trust.trusted_tap?(tap)).to be(true)
  ensure
    Homebrew::Trust.clear!(:tap)
    FileUtils.rm_rf HOMEBREW_TAP_DIRECTORY/"thirdparty"
  end

  it "ignores a trust file with a non-object JSON root" do
    trust_file = HOMEBREW_PREFIX/"var/homebrew/trust.json"
    trust_file.dirname.mkpath
    trust_file.write("[]")

    expect(Homebrew::Trust.trusted?(:tap, "thirdparty/foo")).to be(false)
  ensure
    trust_file&.unlink if trust_file&.exist?
  end
end
