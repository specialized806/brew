# typed: false
# frozen_string_literal: true

RSpec.describe Test::Helper::Subcommand::Args do
  specify "unknown predicates raise" do
    expect { Test::Helper::Subcommand::Args.new(named: []).formuale? }.to raise_error(NoMethodError)
  end
end
