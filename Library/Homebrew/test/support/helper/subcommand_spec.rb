# typed: strict
# frozen_string_literal: true

RSpec.describe Test::Helper::Subcommand::Args do
  specify "unknown predicates raise" do
    expect { described_class.new(named: []).formuale? }.to raise_error(NoMethodError)
  end
end
