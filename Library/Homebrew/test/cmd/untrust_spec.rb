# typed: strict
# frozen_string_literal: true

require "cmd/shared_examples/args_parse"
require "cmd/untrust"
require "trust"

RSpec.describe Homebrew::Cmd::Untrust do
  it_behaves_like "parseable arguments"

  it "untrusts a given tap", :integration_test do
    trust_home = Pathname(TEST_TMPDIR)/"untrust-tap"
    trust_home.mkpath
    (trust_home/"trust.json").write(<<~JSON)
      {
        "trustedtaps": [
          "thirdparty/foo"
        ]
      }
    JSON

    expect { brew "untrust", "thirdparty/foo", "HOMEBREW_USER_CONFIG_HOME" => trust_home.to_s }
      .to output(%r{Untrusted tap: thirdparty/foo}).to_stdout
      .and be_a_success

    expect(trust_home/"trust.json").not_to exist
  ensure
    FileUtils.rm_rf trust_home if trust_home
  end

  it "notes official taps are always trusted" do
    expect { Homebrew::Cmd::Untrust.new(["homebrew/core"]).run }
      .to output("Official tap homebrew/core is always trusted.\n").to_stdout
  end

  it "untrusts a command with the plural switch alias" do
    Homebrew::Trust.trust!(:command, "thirdparty/foo/hello")

    expect { Homebrew::Cmd::Untrust.new(["--commands", "thirdparty/foo/hello"]).run }
      .to output("Untrusted command: thirdparty/foo/hello\n").to_stdout

    expect(Homebrew::Trust.trusted?(:command, "thirdparty/foo/hello")).to be(false)
  ensure
    Homebrew::Trust.clear!(:command)
  end

  it "untrusts trusted items from a tap" do
    Homebrew::Trust.trust!(:formula, "thirdparty/foo/bar")
    Homebrew::Trust.trust!(:cask, "thirdparty/foo/baz")
    Homebrew::Trust.trust!(:command, "thirdparty/foo/hello")

    expect { Homebrew::Cmd::Untrust.new(["thirdparty/foo"]).run }
      .to output("Untrusted tap: thirdparty/foo\n").to_stdout

    expect(Homebrew::Trust.trusted?(:formula, "thirdparty/foo/bar")).to be(false)
    expect(Homebrew::Trust.trusted?(:cask, "thirdparty/foo/baz")).to be(false)
    expect(Homebrew::Trust.trusted?(:command, "thirdparty/foo/hello")).to be(false)
  ensure
    Homebrew::Trust.clear!(:formula)
    Homebrew::Trust.clear!(:cask)
    Homebrew::Trust.clear!(:command)
  end

  it "lists untrusted entries with no arguments" do
    tap = Tap.fetch("thirdparty", "foo")
    tap.cask_dir.mkpath
    (tap.cask_dir/"bar.rb").write("cask 'bar'\n")

    expect { Homebrew::Cmd::Untrust.new([]).run }
      .to output(<<~EOS).to_stdout
        Untrusted taps:
          thirdparty/foo
        Untrusted casks:
          thirdparty/foo/bar
      EOS
  ensure
    FileUtils.rm_rf HOMEBREW_TAP_DIRECTORY/"thirdparty"
  end
end
