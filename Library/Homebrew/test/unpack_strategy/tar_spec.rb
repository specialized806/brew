# typed: true
# frozen_string_literal: true

require_relative "shared_examples"

RSpec.describe UnpackStrategy::Tar do
  subject(:path) { TEST_FIXTURE_DIR/"cask/container.tar.gz" }

  include_examples "UnpackStrategy::detect"
  include_examples "#extract", children: ["container"]

  context "when TAR archive is corrupted" do
    subject(:path) do
      (mktmpdir/"test.tar").tap do |path|
        FileUtils.touch path
      end
    end

    include_examples "UnpackStrategy::detect"
  end
end
