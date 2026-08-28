# typed: strict
# frozen_string_literal: true

require "cmd/shared_examples/args_parse"
require "dev-cmd/install-bundler-gems"

RSpec.describe Homebrew::DevCmd::InstallBundlerGems do
  it_behaves_like "parseable arguments"
  it_behaves_like "a documented command", "install-bundler-gems"

  it "resets Bootsnap after cleaning gems" do
    bundle = "/tmp/bundle"
    allow(Homebrew).to receive(:setup_gem_environment!)
    allow(Homebrew).to receive_messages(valid_gem_groups: [], user_gem_groups: [], user_vendor_version: 9)
    allow(Homebrew).to receive(:find_in_path).with("bundle").and_return("/tmp")
    allow(Homebrew).to receive(:`).with("#{bundle} check 2>&1").and_return("")
    allow(Homebrew).to receive(:system).with(bundle, "clean", out: :err).and_return(true)
    allow(Homebrew).to receive(:write_user_gem_groups)
    expect(Homebrew::Bootsnap).to receive(:reset!)

    Kernel.system("true")
    with_env(HOMEBREW_TESTS: nil) { Homebrew.install_bundler_gems! }
  end
end
