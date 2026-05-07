# typed: false
# frozen_string_literal: true

require "cmd/shared_examples/args_parse"
require "cmd/tap-info"

RSpec.describe Homebrew::Cmd::TapInfo do
  it_behaves_like "parseable arguments"

  it "gets information for a given Tap", :integration_test, :needs_network do
    setup_test_tap

    expect { brew "tap-info", "--json=v1", "--installed" }
      .to output(%r{https://github\.com/Homebrew/homebrew-foo}).to_stdout
      .and not_to_output.to_stderr
      .and be_a_success
  end

  it "display brief statistics for all installed taps", :integration_test, :needs_network do
    expect { brew "tap-info" }
      .to output(/\d+ taps?, \d+ private/).to_stdout
      .and not_to_output.to_stderr
      .and be_a_success
  end

  describe "#decorate_formula" do
    let(:tap_info) { described_class.new([]) }
    let(:tap) { instance_double(Tap, name: "homebrew/foo") }

    before do
      allow($stdout).to receive(:tty?).and_return(true)
      allow_any_instance_of(StringIO).to receive(:tty?).and_return(true)
    end

    it "marks an uninstalled formula as unsatisfied" do
      expect(tap_info.send(:decorate_formula, tap, "missing", installed: false)).to match(/missing.*✘/)
    end

    it "marks an installed formula as satisfied" do
      formula = instance_double(Formula, outdated?: false)
      allow(Formulary).to receive(:factory).with("homebrew/foo/installed").and_return(formula)

      expect(tap_info.send(:decorate_formula, tap, "installed", installed: true)).to match(/installed.*✔/)
    end

    it "marks an outdated installed formula as upgradable" do
      formula = instance_double(Formula, outdated?: true)
      allow(Formulary).to receive(:factory).with("homebrew/foo/outdated").and_return(formula)

      expect(tap_info.send(:decorate_formula, tap, "outdated", installed: true)).to match(/outdated.*↑/)
    end
  end

  describe "#decorate_cask" do
    let(:tap_info) { described_class.new([]) }
    let(:tap) { instance_double(Tap, name: "homebrew/foo") }

    before do
      allow($stdout).to receive(:tty?).and_return(true)
      allow_any_instance_of(StringIO).to receive(:tty?).and_return(true)
    end

    it "marks an uninstalled cask as unsatisfied" do
      expect(tap_info.send(:decorate_cask, tap, "missing", installed: false)).to match(/missing.*✘/)
    end

    it "marks an installed cask as satisfied" do
      cask = instance_double(Cask::Cask, outdated?: false)
      allow(Cask::CaskLoader).to receive(:load).with("homebrew/foo/installed").and_return(cask)

      expect(tap_info.send(:decorate_cask, tap, "installed", installed: true)).to match(/installed.*✔/)
    end

    it "marks an outdated installed cask as upgradable" do
      cask = instance_double(Cask::Cask, outdated?: true)
      allow(Cask::CaskLoader).to receive(:load).with("homebrew/foo/outdated").and_return(cask)

      expect(tap_info.send(:decorate_cask, tap, "outdated", installed: true)).to match(/outdated.*↑/)
    end
  end

  describe "#print_tap_listings" do
    let(:tap_info) { described_class.new([]) }

    before do
      allow_any_instance_of(StringIO).to receive(:tty?).and_return(true)
    end

    context "with a small tap and a mix of installed and uninstalled entries" do
      let(:tap) do
        instance_double(
          Tap,
          name:          "homebrew/foo",
          remote:        "https://github.com/homebrew/homebrew-foo",
          command_files: [Pathname("/some/tap/cmd/brew-mycmd.rb")],
          formula_names: ["homebrew/foo/foo", "homebrew/foo/uninstalled-formula"],
          cask_tokens:   ["homebrew/foo/bar", "homebrew/foo/uninstalled-cask"],
        )
      end

      before do
        allow(Formula).to receive(:installed_formula_names).and_return(["foo"])
        allow(Cask::Caskroom).to receive(:tokens).and_return(["bar"])
        allow(Formulary).to receive(:factory).with("homebrew/foo/foo")
                                             .and_return(instance_double(Formula, outdated?: false))
        allow(Cask::CaskLoader).to receive(:load).with("homebrew/foo/bar")
                                                 .and_return(instance_double(Cask::Cask, outdated?: false))
      end

      it "lists every formula and cask with mixed install markers under their headers" do
        expect { tap_info.send(:print_tap_listings, tap) }
          .to output(
            /Commands.*mycmd.*==> Formulae.*foo.*✔.*uninstalled-formula.*✘.*==> Casks.*bar.*✔.*uninstalled-cask.*✘/m,
          ).to_stdout
      end
    end

    context "with a large tap and some installed entries" do
      let(:formula_names) { (1..40).map { |i| "homebrew/foo/formula#{i}" } }
      let(:tap) do
        instance_double(
          Tap,
          name:          "homebrew/foo",
          remote:        "https://github.com/homebrew/homebrew-foo",
          command_files: [],
          formula_names: formula_names,
          cask_tokens:   [],
        )
      end

      before do
        allow(Formula).to receive(:installed_formula_names).and_return(["formula7"])
        allow(Cask::Caskroom).to receive(:tokens).and_return([])
        allow(Formulary).to receive(:factory).with("homebrew/foo/formula7")
                                             .and_return(instance_double(Formula, outdated?: false))
      end

      it "warns about truncation and shows only installed entries under the standard header" do
        expect { tap_info.send(:print_tap_listings, tap) }
          .to output(/==> Formulae.*formula7.*✔/m).to_stdout
          .and output(/Tap has more than 30 formulae; showing only installed entries\./).to_stderr
      end
    end

    context "with a small tap and nothing installed" do
      let(:tap) do
        instance_double(
          Tap,
          name:          "homebrew/foo",
          remote:        "https://github.com/homebrew/homebrew-foo",
          command_files: [],
          formula_names: ["homebrew/foo/foo", "homebrew/foo/baz"],
          cask_tokens:   ["homebrew/foo/bar"],
        )
      end

      before do
        allow(Formula).to receive(:installed_formula_names).and_return([])
        allow(Cask::Caskroom).to receive(:tokens).and_return([])
      end

      it "lists every formula and cask with uninstalled markers" do
        expect { tap_info.send(:print_tap_listings, tap) }
          .to output(/==> Formulae.*baz.*✘.*foo.*✘.*==> Casks.*bar.*✘/m).to_stdout
      end
    end

    context "with a large tap and nothing installed" do
      let(:formula_names) { (1..40).map { |i| "homebrew/foo/formula#{i}" } }
      let(:tap) do
        instance_double(
          Tap,
          name:          "homebrew/foo",
          remote:        "https://github.com/homebrew/homebrew-foo",
          command_files: [],
          formula_names: formula_names,
          cask_tokens:   [],
        )
      end

      before do
        allow(Formula).to receive(:installed_formula_names).and_return([])
        allow(Cask::Caskroom).to receive(:tokens).and_return([])
      end

      it "shows a link to the tap remote and warns when nothing is installed" do
        expect { tap_info.send(:print_tap_listings, tap) }
          .to output(%r{See: https://github.com/homebrew/homebrew-foo}).to_stdout
          .and output(/Tap has more than 30 formulae and none are installed\./).to_stderr
      end

      it "does not list individual formula names" do
        expect { tap_info.send(:print_tap_listings, tap) }
          .not_to output(/formula1\b/).to_stdout
      end
    end
  end
end
