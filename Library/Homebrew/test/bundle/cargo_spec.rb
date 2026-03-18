# frozen_string_literal: true

require "bundle"
require "bundle/cargo"

RSpec.describe Homebrew::Bundle::Cargo do
  describe "dumping" do
    subject(:dumper) { described_class }

    context "when cargo is not installed" do
      before do
        described_class.reset!
        allow(Homebrew::Bundle).to receive(:cargo_installed?).and_return(false)
      end

      it "returns an empty list" do
        expect(dumper.packages).to be_empty
      end

      it "dumps an empty string" do # rubocop:todo RSpec/AggregateExamples
        expect(dumper.dump).to eql("")
      end
    end

    context "when cargo is installed" do
      before do
        described_class.reset!
        allow(Homebrew::Bundle).to receive_messages(cargo_installed?: true, which_cargo: Pathname.new("cargo"))
      end

      it "returns package list" do
        allow(described_class).to receive(:`).with("cargo install --list").and_return(<<~EOS)
          ripgrep v13.0.0:
              rg
          bat v0.24.0 (/Users/test/.cargo/bin/bat)
        EOS

        expect(dumper.packages).to eql(%w[ripgrep bat])
      end

      it "dumps package list" do
        allow(dumper).to receive(:packages).and_return(["ripgrep", "bat"])
        expect(dumper.dump).to eql("cargo \"ripgrep\"\ncargo \"bat\"")
      end
    end
  end

  describe "installing" do
    context "when Cargo is not installed" do
      before do
        described_class.reset!
        allow(Homebrew::Bundle).to receive(:cargo_installed?).and_return(false)
      end

      it "tries to install rust" do
        expect(Homebrew::Bundle).to \
          receive(:system).with(HOMEBREW_BREW_FILE, "install", "--formula", "rust", verbose: false)
                          .and_return(true)
        expect { described_class.preinstall!("ripgrep") }.to raise_error(RuntimeError)
      end
    end

    context "when Cargo is installed" do
      before do
        allow(Homebrew::Bundle).to receive(:cargo_installed?).and_return(true)
      end

      context "when package is installed" do
        before do
          allow(described_class).to receive(:installed_packages)
            .and_return(["ripgrep"])
        end

        it "skips" do
          expect(Homebrew::Bundle).not_to receive(:system)
          expect(described_class.preinstall!("ripgrep")).to be(false)
        end
      end

      context "when package is not installed" do
        before do
          allow(Homebrew::Bundle).to receive(:which_cargo).and_return(Pathname.new("/tmp/rust/bin/cargo"))
          allow(described_class).to receive(:installed_packages).and_return([])
        end

        it "installs package" do
          expect(Homebrew::Bundle).to receive(:system) do |*args, verbose:|
            expect(ENV.fetch("PATH", "")).to start_with("/tmp/rust/bin:")
            expect(args).to eq(["/tmp/rust/bin/cargo", "install", "--locked", "ripgrep"])
            expect(verbose).to be(false)
            true
          end
          expect(described_class.preinstall!("ripgrep")).to be(true)
          expect(described_class.install!("ripgrep")).to be(true)
        end
      end
    end
  end
end
