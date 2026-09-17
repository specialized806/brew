# typed: strict
# frozen_string_literal: true

require "open3"

RSpec.describe "package postinstall", type: :system do
  # Keep each Sorbet signature with its let declaration.
  # rubocop:disable RSpec/ScatteredLet
  sig { returns(Pathname) }
  let(:test_root) { mktmpdir }

  sig { returns(Pathname) }
  let(:prefix) { test_root/"prefix" }

  sig { returns(Integer) }
  let(:install_uid) { 501 }

  sig { returns(Pathname) }
  let(:commands) { test_root/"commands" }

  sig { returns([String, String, Process::Status]) }
  let(:result) do
    Open3.capture3("/bin/bash", "-c", <<~SH)
      id() { echo #{install_uid}; }
      chmod() { :; }
      chown() { echo "chown $*" >> "#{commands}"; }
      git() {
        echo "git $*" >> "#{commands}"
        if [[ "$*" == *" tag "* ]]; then echo 7.0.3; fi
      }
      sudo() {
        if [[ "$*" != *" git "* ]]; then exit 0; fi
        echo "sudo $*" >> "#{commands}"
        if [[ "$*" == *" tag "* ]]; then echo 7.0.3; fi
      }
      source "#{test_root}/postinstall" "" "#{prefix}"
    SH
  end
  # rubocop:enable RSpec/ScatteredLet

  before do
    (prefix/"bin").mkpath
    commands.write ""
    FileUtils.cp HOMEBREW_LIBRARY_PATH.parent.parent/"package/scripts/postinstall", test_root/"postinstall"
    (test_root/"macos_user.sh").write <<~SH
      homebrew-package-user() { echo pkg-user; }
      homebrew-user-home() { echo "#{test_root}"; }
    SH
  end

  it "runs Git as the install user after setting ownership" do
    _, stderr, status = result
    git_command = "sudo -u pkg-user /usr/bin/env HOME=#{prefix} GIT_CONFIG_GLOBAL=/dev/null " \
                  "PATH=/Library/Developer/CommandLineTools/usr/bin:" \
                  "/Applications/Xcode.app/Contents/Developer/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin " \
                  "git -c core.hooksPath=/dev/null -C #{prefix}"

    expect([status.exitstatus, stderr, commands.read.lines(chomp: true)]).to eq([
      0, "", [
        "chown -R pkg-user:admin .",
        "#{git_command} tag --list --sort=-version:refname",
        "#{git_command} checkout --force -B stable",
        "#{git_command} reset --hard 7.0.3",
        "#{git_command} clean -f -d",
      ]
    ])
  end

  context "when the install user has UID 0" do
    sig { returns(Integer) }
    let(:install_uid) { 0 }

    it "rejects the account before changing ownership or running Git" do
      stdout, _, status = result

      expect([status.exitstatus, stdout.lines.last, commands.read]).to eq([
        1, "The Homebrew installation user must not be root.\n", ""
      ])
    end
  end
end
