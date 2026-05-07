# typed: false
# frozen_string_literal: true

require "cmd/desc"
require "cmd/shared_examples/args_parse"

RSpec.describe Homebrew::Cmd::Desc do
  it_behaves_like "parseable arguments"

  it "shows a given Formula's description", :integration_test do
    setup_test_formula "testball"

    expect { brew "desc", "testball" }
      .to output("testball: Some test\n").to_stdout
      .and not_to_output.to_stderr
      .and be_a_success
  end

  it "shows an installed Cask's description with status" do
    allow_any_instance_of(StringIO).to receive(:tty?).and_return(true)
    cask = Cask::Cask.new("local-transmission") do
      version "2.61"
      name "Transmission"
      desc "BitTorrent client"
      url "https://example.com/local-transmission.zip"
    end
    cmd = described_class.new(["--cask", "local-transmission"])

    allow(cmd.args.named).to receive(:to_formulae_and_casks).and_return([cask])
    allow(Cask::Caskroom).to receive(:casks).and_return([cask])
    allow(Formulary).to receive(:factory)
      .with("local-transmission")
      .and_raise(FormulaUnavailableError.new("local-transmission"))
    allow(Cask::CaskLoader).to receive(:load).with("local-transmission").and_return(cask)

    expect { cmd.run }
      .to output(/local-transmission .*✔.*: \(Transmission\) BitTorrent client/).to_stdout
      .and not_to_output.to_stderr
  end

  it "omits a Cask without a description" do
    cask = Cask::Cask.new("no-description") do
      version "1.0"
      name "No Description"
      url "https://example.com/no-description.zip"
    end
    cmd = described_class.new(["--cask", "no-description"])

    allow(cmd.args.named).to receive(:to_formulae_and_casks).and_return([cask])

    expect { cmd.run }
      .to not_to_output.to_stdout
      .and not_to_output.to_stderr
  end

  it "errors when searching without --eval-all", :integration_test, :no_api do
    setup_test_formula "testball"

    expect { brew "desc", "--search", "testball" }
      .to output(/`brew desc --search` needs `--eval-all` passed or `HOMEBREW_EVAL_ALL=1` set!/).to_stderr
      .and be_a_failure
  end

  it "successfully searches with --search --eval-all", :integration_test, :no_api do
    setup_test_formula "testball"

    expect { brew "desc", "--search", "--eval-all", "ball" }
      .to output(/testball: Some test/).to_stdout
      .and not_to_output.to_stderr
  end

  it "successfully searches without --eval-all, with API", :integration_test, :needs_network do
    setup_test_formula "testball"

    expect { brew "desc", "--search", "testball" }.to be_a_success
  end
end
