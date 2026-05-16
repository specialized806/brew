# typed: false
# frozen_string_literal: true

require "sandbox"

RSpec.describe Sandbox do
  subject(:sandbox) { described_class.new }

  describe "::executable" do
    let(:sandbox_class) do
      Class.new(described_class) do
        class << self
          attr_accessor :test_executable_name, :unsuitable_executables

          def executable_name = test_executable_name

          def executable_usable?(candidate)
            unsuitable_executables.exclude?(candidate)
          end
        end
      end
    end
    let(:first_dir) { mktmpdir }
    let(:second_dir) { mktmpdir }
    let(:homebrew_bin) { mktmpdir }
    let(:executable_name) { "sandbox-tool" }
    let(:first_executable) { first_dir/executable_name }
    let(:second_executable) { second_dir/executable_name }
    let(:homebrew_executable) { homebrew_bin/executable_name }

    before do
      sandbox_class.test_executable_name = executable_name
      sandbox_class.unsuitable_executables = []
      stub_const("HOMEBREW_ORIGINAL_BREW_FILE", homebrew_bin/"brew")
    end

    it "uses the first suitable executable candidate" do
      FileUtils.touch first_executable
      FileUtils.chmod "+x", first_executable
      FileUtils.touch second_executable
      FileUtils.chmod "+x", second_executable
      stub_const("ORIGINAL_PATHS", [first_dir])

      with_env(PATH: second_dir.to_s) do
        expect(sandbox_class.executable).to eq(first_executable)
      end
    end

    it "skips unsuitable executable candidates" do
      FileUtils.touch first_executable
      FileUtils.chmod "+x", first_executable
      FileUtils.touch second_executable
      FileUtils.chmod "+x", second_executable
      stub_const("ORIGINAL_PATHS", [first_dir])
      sandbox_class.unsuitable_executables = [first_executable]

      with_env(PATH: second_dir.to_s) do
        expect(sandbox_class.executable).to eq(second_executable)
      end
    end

    it "falls back to the original Homebrew bin directory" do
      FileUtils.touch homebrew_executable
      FileUtils.chmod "+x", homebrew_executable
      stub_const("ORIGINAL_PATHS", [])

      with_env(PATH: mktmpdir.to_s) do
        expect(sandbox_class.executable).to eq(homebrew_executable)
      end
    end

    it "checks absolute executable paths directly" do
      FileUtils.touch first_executable
      FileUtils.chmod "+x", first_executable
      sandbox_class.test_executable_name = first_executable.to_s
      stub_const("ORIGINAL_PATHS", [])

      with_env(PATH: mktmpdir.to_s) do
        expect(sandbox_class.executable).to eq(first_executable)
      end
    end

    it "raises when no executable candidate exists" do
      stub_const("ORIGINAL_PATHS", [])

      with_env(PATH: mktmpdir.to_s) do
        expect { sandbox_class.executable! }
          .to raise_error(RuntimeError, "#{executable_name} is required to use the sandbox.")
      end
    end
  end

  describe "#path_filter" do
    ["'", '"', "(", ")", "\n", "\\"].each do |char|
      it "fails if the path contains #{char}" do
        expect do
          sandbox.path_filter("foo#{char}bar", :subpath)
        end.to raise_error(ArgumentError)
      end
    end
  end

  describe "#allow_read_if_exists" do
    it "allows reads for existing paths" do
      file = mktmpdir/"foo.rb"
      FileUtils.touch file

      sandbox.allow_read_if_exists path: file

      rule = sandbox.send(:profile).rules.fetch(-1)
      expect(rule).to have_attributes(allow: true, operation: "file-read*")
      expect(rule.filter).to have_attributes(path: file.realpath.to_s, type: :literal)
    end

    it "skips missing paths" do
      sandbox.allow_read_if_exists path: mktmpdir/"missing.rb"

      expect(sandbox.send(:profile).rules).to be_empty
    end

    it "skips nil paths" do
      sandbox.allow_read_if_exists path: nil

      expect(sandbox.send(:profile).rules).to be_empty
    end
  end

  describe "#allow_write_path_if_exists" do
    it "allows writes for existing paths" do
      dir = mktmpdir/"foo"
      dir.mkpath

      sandbox.allow_write_path_if_exists dir

      rule = sandbox.send(:profile).rules.fetch(0)
      expect(rule).to have_attributes(allow: true, operation: "file-write*")
      expect(rule.filter).to have_attributes(path: dir.realpath.to_s, type: :subpath)
    end

    it "skips missing paths" do
      sandbox.allow_write_path_if_exists mktmpdir/"missing"

      expect(sandbox.send(:profile).rules).to be_empty
    end

    it "skips nil paths" do
      sandbox.allow_write_path_if_exists nil

      expect(sandbox.send(:profile).rules).to be_empty
    end
  end

  describe "#allow_write_cellar" do
    it "fails when the formula has a name including )" do
      f = formula do
        url "https://brew.sh/foo-1.0.tar.gz"
        version "1.0"

        def initialize(*, **)
          super
          @name = "foo)bar"
        end
      end

      expect do
        sandbox.allow_write_cellar f
      end.to raise_error(ArgumentError)
    end

    it "fails when the formula has a name including \"" do
      f = formula do
        url "https://brew.sh/foo-1.0.tar.gz"
        version "1.0"

        def initialize(*, **)
          super
          @name = "foo\"bar"
        end
      end

      expect do
        sandbox.allow_write_cellar f
      end.to raise_error(ArgumentError)
    end
  end
end
