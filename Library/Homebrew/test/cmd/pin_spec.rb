# typed: false
# frozen_string_literal: true

require "cmd/pin"
require "cmd/shared_examples/args_parse"

RSpec.describe Homebrew::Cmd::Pin do
  it_behaves_like "parseable arguments"

  it "pins a Formula's version", :integration_test do
    setup_test_formula "testball", tab_attributes: { installed_on_request: true }

    expect { brew "pin", "testball" }.to be_a_success
  end

  it "pins a Cask's version", :cask, :integration_test do
    cask = Cask::CaskLoader.load("local-caffeine")
    InstallHelper.stub_cask_installation(cask)

    expect { brew "pin", "--cask", "local-caffeine" }.to be_a_success

    expect(cask).to be_pinned
    expect(cask.pinned_version).to eq("1.2.3")
    cask.unpin
  end

  it "warns when pinning a Cask with auto_updates true", :cask, :integration_test do
    cask = Cask::CaskLoader.load("auto-updates")
    InstallHelper.stub_cask_installation(cask)

    expect do
      expect { brew "pin", "--cask", "auto-updates" }.to be_a_success
    end.to output(/auto-updates has `auto_updates true`.*outside Homebrew/).to_stderr

    cask.unpin
  end

  it "fails with an uninstalled Formula", :integration_test do
    setup_test_formula "testball"

    expect { brew "pin", "testball" }.to be_a_failure
  end
end
