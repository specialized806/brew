# typed: true
# frozen_string_literal: true

RSpec.describe Test::Helper::Subcommand::Args do
  specify "unknown predicates raise" do
    expect do
      T.unsafe(described_class.new(named: [])).formuale?
    end.to raise_error(NoMethodError)
  end
end
