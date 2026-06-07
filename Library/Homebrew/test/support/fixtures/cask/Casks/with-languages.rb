# typed: false

cask "with-languages" do
  version "1.2.3"

  language "zh" do
    sha256 :no_check
    "zh-CN"
  end
  language "en-US", default: true do
    sha256 :no_check
    "en-US"
  end

  url "file://#{TEST_FIXTURE_DIR}/cask/caffeine.zip"
  name "Caffeine"
  homepage "https://brew.sh/"

  depends_on macos: :catalina

  app "Caffeine.app"
end
