# typed: false
# frozen_string_literal: true

require "cmd/shared_examples/args_parse"
require "dev-cmd/bump-formula-pr"

RSpec.describe Homebrew::DevCmd::BumpFormulaPr do
  subject(:bump_formula_pr) { described_class.new(["test"]) }

  let(:f) do
    formula("test") do
      url "https://brew.sh/test-1.2.3.tgz"
    end
  end

  it_behaves_like "parseable arguments"

  describe "::check_throttle" do
    let(:tap) { Tap.fetch("test", "tap") }

    let(:f_throttle) do
      formula("throttle-test") do
        url "https://brew.sh/test-1.2.3.tgz"

        livecheck do
          throttle 5
        end
      end
    end

    let(:f_throttle_days) do
      formula("throttle-days-test") do
        url "https://brew.sh/test-1.2.3.tgz"

        livecheck do
          throttle days: 1
        end
      end
    end

    let(:f_throttle_rate_and_days) do
      formula("throttle-rate-and-days-test") do
        url "https://brew.sh/test-1.2.3.tgz"

        livecheck do
          throttle 5, days: 1
        end
      end
    end

    let(:throttle_error) { "Error: throttle-test should only be updated every 5 releases on multiples of 5\n" }
    let(:throttle_days_error) { "Error: throttle-days-test should only be updated every 1 day\n" }
    let(:throttle_rate_days_error) do
      "Error: throttle-rate-and-days-test should only be updated every 5 releases on multiples of 5 or 1 day\n"
    end

    context "when formula is not in a tap" do
      it "outputs nothing" do
        allow(f).to receive(:tap).and_return(nil)

        expect { bump_formula_pr.send(:check_throttle, f, "1.2.4") }.not_to output.to_stderr
      end
    end

    context "when a livecheck throttle value isn't present" do
      it "does not throttle" do
        allow(f).to receive(:tap).and_return(tap)

        expect { bump_formula_pr.send(:check_throttle, f, "1.2.4") }.not_to output.to_stderr
      end
    end

    context "when patch version is a multiple of throttle rate" do
      it "does not throttle" do
        allow(f_throttle).to receive(:tap).and_return(tap)

        expect { bump_formula_pr.send(:check_throttle, f_throttle, "1.2.5") }.not_to output.to_stderr
      end
    end

    context "when patch version is not a multiple of throttle rate" do
      it "throttles version" do
        allow(f_throttle).to receive(:tap).and_return(tap)

        expect do
          bump_formula_pr.send(:check_throttle, f_throttle, "1.2.4")
        rescue SystemExit
          nil
        end.to output(throttle_error).to_stderr
      end
    end

    context "when patch version is not a multiple and throttle days are set" do
      before do
        allow(f_throttle_rate_and_days).to receive(:tap).and_return(tap)
      end

      it "throttles version when throttle interval has not elapsed" do
        allow(Homebrew::Livecheck).to receive(:throttle_interval_elapsed?).and_return(false)

        expect do
          bump_formula_pr.send(:check_throttle, f_throttle_rate_and_days, "1.2.4")
        rescue SystemExit
          nil
        end.to output(throttle_rate_days_error).to_stderr
      end

      it "does not throttle when throttle interval has elapsed" do
        allow(Homebrew::Livecheck).to receive(:throttle_interval_elapsed?).and_return(true)

        expect { bump_formula_pr.send(:check_throttle, f_throttle_rate_and_days, "1.2.4") }.not_to output.to_stderr
      end
    end

    context "when only throttle days is set" do
      before do
        allow(f_throttle_days).to receive(:tap).and_return(tap)
      end

      it "throttles version when throttle interval has not elapsed" do
        allow(Homebrew::Livecheck).to receive(:throttle_interval_elapsed?).and_return(false)

        expect do
          bump_formula_pr.send(:check_throttle, f_throttle_days, "1.2.4")
        rescue SystemExit
          next
        end.to output(throttle_days_error).to_stderr
      end

      it "does not throttle when throttle interval has elapsed" do
        allow(Homebrew::Livecheck).to receive(:throttle_interval_elapsed?).and_return(true)

        expect do
          bump_formula_pr.send(:check_throttle, f_throttle_days, "1.2.4")
        end.not_to output.to_stderr
      end
    end
  end
end
