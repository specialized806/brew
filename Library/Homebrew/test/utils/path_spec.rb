# typed: strict
# frozen_string_literal: true

require "utils/path"

RSpec.describe Utils::Path do
  describe "::child_of?" do
    it "recognizes a path as its own child" do
      expect(described_class.child_of?("/foo/bar", "/foo/bar")).to be(true)
    end

    it "recognizes a path that is a child of the parent" do
      expect(described_class.child_of?("/foo", "/foo/bar")).to be(true)
    end

    it "recognizes a path that is a grandchild of the parent" do
      expect(described_class.child_of?("/foo", "/foo/bar/baz")).to be(true)
    end

    it "does not recognize a path that is not a child" do
      expect(described_class.child_of?("/foo", "/bar/baz")).to be(false)
    end

    it "handles . and .. in paths correctly" do
      expect(described_class.child_of?("/foo", "/foo/./bar")).to be(true)
      expect(described_class.child_of?("/foo/bar", "/foo/../foo/bar/baz")).to be(true)
    end

    it "handles relative paths correctly" do
      expect(described_class.child_of?("foo", "./bar/baz")).to be(false)
      expect(described_class.child_of?("../foo", "./bar/baz/../../../foo/bar/baz")).to be(true)
    end
  end

  describe "::formula_opt_bin" do
    it "returns a formula opt bin path without loading a Formula object" do
      expect(described_class.formula_opt_bin("foo")).to eq(HOMEBREW_PREFIX/"opt/foo/bin")
    end
  end

  describe "::formula_opt_bin_path" do
    it "prepends a formula opt bin path to the current PATH by default" do
      expect(described_class.formula_opt_bin_path("foo")).to eq(PATH.new(HOMEBREW_PREFIX/"opt/foo/bin",
                                                                         ENV.fetch("PATH")))
    end

    it "prepends a formula opt bin path to PATH entries" do
      expect(described_class.formula_opt_bin_path("foo", "/usr/bin")).to eq(PATH.new(HOMEBREW_PREFIX/"opt/foo/bin",
                                                                                     "/usr/bin",
                                                                                     ENV.fetch("PATH")))
    end
  end

  describe "::formula_opt_bin_env" do
    it "returns a PATH environment with a formula opt bin path prepended to the current PATH by default" do
      expect(described_class.formula_opt_bin_env("foo"))
        .to eq({ "PATH" => PATH.new(HOMEBREW_PREFIX/"opt/foo/bin", ENV.fetch("PATH")).to_s })
    end

    it "returns a PATH environment with extra PATH entries" do
      expect(described_class.formula_opt_bin_env("foo", "/usr/bin"))
        .to eq({ "PATH" => PATH.new(HOMEBREW_PREFIX/"opt/foo/bin", "/usr/bin", ENV.fetch("PATH")).to_s })
    end
  end

  describe "::loadable_package_path?" do
    it "accepts formula paths under a symlinked cellar" do
      tmpdir = mktmpdir
      real_cellar = tmpdir/"real-cellar"
      symlink_cellar = tmpdir/"cellar"

      real_cellar.mkpath
      FileUtils.ln_s(real_cellar, symlink_cellar)
      stub_const("HOMEBREW_CELLAR", symlink_cellar)
      allow(Homebrew::EnvConfig).to receive(:forbid_packages_from_paths?).and_return(true)

      formula_path = real_cellar/"poshtui/0.16/.brew/poshtui.rb"
      formula_path.dirname.mkpath
      formula_path.write <<~RUBY
        class Poshtui < Formula; end
      RUBY

      expect(described_class.loadable_package_path?(formula_path, :formula)).to be(true)
    end
  end
end
