# typed: false
# frozen_string_literal: true

require "utils/svn"

RSpec.describe Utils::Svn do
  let(:klass) { Utils::Svn }

  before do
    klass.clear_version_cache
  end

  describe "::available?" do
    it "returns svn version if svn available" do
      if quiet_system "#{HOMEBREW_SHIMS_PATH}/shared/svn", "--version"
        expect(klass).to be_available
      else
        expect(klass).not_to be_available
      end
    end
  end

  describe "::version" do
    it "returns svn version if svn available" do
      if quiet_system "#{HOMEBREW_SHIMS_PATH}/shared/svn", "--version"
        expect(klass.version).to match(/^\d+\.\d+\.\d+$/)
      else
        expect(klass.version).to be_nil
      end
    end

    it "returns version of svn when svn is available", :needs_svn do
      expect(klass.version).not_to be_nil
    end
  end

  describe "::remote_exists?" do
    it "returns true when svn is not available" do
      allow(klass).to receive(:available?).and_return(false)
      expect(klass).to be_remote_exists("blah")
    end

    context "when svn is available" do
      before do
        allow(klass).to receive(:available?).and_return(true)
      end

      it "returns false when remote does not exist" do
        expect(klass).not_to be_remote_exists("blah")
      end

      it "returns true when remote exists", :needs_network, :needs_svn do
        expect(klass).to be_remote_exists("https://svn.code.sf.net/p/ctags/code/trunk")
      end
    end
  end
end
