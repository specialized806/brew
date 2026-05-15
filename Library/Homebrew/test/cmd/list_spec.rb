# typed: false
# frozen_string_literal: true

require "cmd/list"
require "cmd/shared_examples/args_parse"

RSpec.describe Homebrew::Cmd::List do
  let(:formulae) { %w[bar foo qux] }

  it_behaves_like "parseable arguments"

  it "prints all installed formulae", :integration_test do
    formulae.each do |f|
      (HOMEBREW_CELLAR/f/"1.0/somedir").mkpath
    end

    expect { brew "list", "--formula" }
      .to output("#{formulae.join("\n")}\n").to_stdout
      .and not_to_output.to_stderr
      .and be_a_success
  end

  it "prints all installed formulae and casks", :integration_test do
    expect { brew_sh "list" }
      .to be_a_success
      .and not_to_output.to_stderr
  end

  it "prints pinned formulae and casks", :cask, :integration_test do
    setup_test_formula "testball", tab_attributes: { installed_on_request: true }
    Formula["testball"].pin
    cask = Cask::CaskLoader.load("local-caffeine")
    InstallHelper.stub_cask_installation(cask)
    cask.pin

    expect { brew "list", "--pinned", "--versions" }
      .to output("local-caffeine 1.2.3\ntestball 0.1\n").to_stdout
      .and be_a_success

    cask.unpin
  end

  it "fails only for explicitly named missing pinned packages", :cask, :integration_test do
    setup_test_formula "testball", tab_attributes: { installed_on_request: true }
    Formula["testball"].pin
    cask = Cask::CaskLoader.load("local-caffeine")
    InstallHelper.stub_cask_installation(cask)
    cask.pin

    expect { brew "list", "--pinned", "--versions", "testball", "local-caffeine", "missing" }
      .to output("local-caffeine 1.2.3\ntestball 0.1\n").to_stdout
      .and be_a_failure

    cask.unpin
  end

  it "warns for explicitly named unpinned packages", :cask, :integration_test do
    cask = Cask::CaskLoader.load("local-caffeine")
    InstallHelper.stub_cask_installation(cask)

    expect { brew "list", "--pinned", "--cask", "local-caffeine" }
      .to not_to_output.to_stdout
      .and output(/local-caffeine not pinned/).to_stderr
      .and be_a_success
  end

  it "does not fail for unpinned Caskroom entries without named arguments", :cask, :integration_test do
    (Cask::Caskroom.path/"broken").mkpath

    expect { brew "list", "--pinned", "--cask" }
      .to not_to_output.to_stdout
      .and be_a_success
  end
end
