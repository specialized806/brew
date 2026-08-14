# typed: strict
# frozen_string_literal: true

require "cask/installer"
require "cask/reinstall"

RSpec.describe Cask::Reinstall, :cask do
  it "displays the reinstallation progress" do
    caffeine = Cask::CaskLoader.load(cask_path("local-caffeine"))

    Cask::Installer.new(caffeine).install

    output = Regexp.new <<~EOS
      ==> Uninstalling Cask local-caffeine
      ==> Backing up App 'Caffeine.app' to '.*Caffeine.app'
      ==> Removing App '.*Caffeine.app'
      ==> Purging files for version 1.2.3 of Cask local-caffeine
      ==> Installing Cask local-caffeine
      ==> Moving App 'Caffeine.app' to '.*Caffeine.app'
      .*local-caffeine was successfully installed!
    EOS

    expect do
      described_class.reinstall_casks(Cask::CaskLoader.load("local-caffeine"))
    end.to output(output).to_stdout.and output(/==> Fetching downloads for:.*caffeine/).to_stderr
  end

  it "displays the reinstallation progress with zapping" do
    caffeine = Cask::CaskLoader.load(cask_path("local-caffeine"))

    Cask::Installer.new(caffeine).install

    output = Regexp.new <<~EOS
      ==> Backing up App 'Caffeine.app' to '.*Caffeine.app'
      ==> Removing App '.*Caffeine.app'
      ==> Dispatching zap stanza
      ==> Trashing files:
      .*org.example.caffeine.plist
      ==> Removing all staged versions of Cask 'local-caffeine'
      ==> Installing Cask local-caffeine
      ==> Moving App 'Caffeine.app' to '.*Caffeine.app'
      .*local-caffeine was successfully installed!
    EOS

    expect do
      described_class.reinstall_casks(Cask::CaskLoader.load("local-caffeine"), zap: true)
    end.to output(output).to_stdout.and output(/==> Fetching downloads for:.*caffeine/).to_stderr
  end

  it "allows reinstalling a Cask" do
    Cask::Installer.new(Cask::CaskLoader.load(cask_path("local-transmission-zip"))).install

    expect(Cask::CaskLoader.load(cask_path("local-transmission-zip"))).to be_installed

    described_class.reinstall_casks(Cask::CaskLoader.load("local-transmission-zip"))
    expect(Cask::CaskLoader.load(cask_path("local-transmission-zip"))).to be_installed
  end

  it "continues reinstalling remaining casks when one raises" do
    cask1 = Cask::CaskLoader.load(cask_path("local-caffeine"))
    cask2 = Cask::CaskLoader.load(cask_path("local-transmission-zip"))

    Cask::Installer.new(cask1).install
    Cask::Installer.new(cask2).install

    failing_installer = instance_double(Cask::Installer, cask: cask1)
    allow(failing_installer).to receive(:prelude)
    allow(failing_installer).to receive(:source_download_requires_pre_fetch?).and_return(false)
    allow(failing_installer).to receive(:enqueue_downloads)
    allow(failing_installer).to receive(:install).and_raise(Cask::CaskError.new("reinstall failed"))

    successful_installer = instance_double(Cask::Installer)
    allow(successful_installer).to receive(:prelude)
    allow(successful_installer).to receive(:source_download_requires_pre_fetch?).and_return(false)
    allow(successful_installer).to receive(:enqueue_downloads)

    allow(Cask::Installer).to receive(:new).and_return(failing_installer, successful_installer)

    expect(successful_installer).to receive(:install)
    expect { described_class.reinstall_casks(cask1, cask2) }
      .to output(/local-caffeine: reinstall failed/).to_stderr
  end

  it "reinstalls casks after an earlier failure in the same run" do
    cask = Cask::CaskLoader.load(cask_path("local-caffeine"))
    installer = instance_double(Cask::Installer, prelude: nil, enqueue_downloads: nil,
                                                 source_download_requires_pre_fetch?: false)
    allow(Cask::Installer).to receive(:new).and_return(installer)
    # A failure earlier in the run (e.g. a formula in the same `brew reinstall`)
    # must not stop the casks that are ready from being reinstalled.
    Homebrew.failed = true

    expect(installer).to receive(:install)

    described_class.reinstall_casks(cask)
  end

  it "allows reinstalling a non installed Cask" do
    expect(Cask::CaskLoader.load(cask_path("local-transmission-zip"))).not_to be_installed

    described_class.reinstall_casks(Cask::CaskLoader.load("local-transmission-zip"))
    expect(Cask::CaskLoader.load(cask_path("local-transmission-zip"))).to be_installed
  end
end
