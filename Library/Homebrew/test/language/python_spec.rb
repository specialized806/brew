# typed: strict
# frozen_string_literal: true

require "language/python"

RSpec.describe Language::Python, :needs_python do
  describe ".direct_dependency_paths", needs_python: false do
    it "returns unique stable paths for tap-qualified direct Python dependencies" do
      f = formula "foo" do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/foo-1.0.tgz"

        depends_on "homebrew/core/python@3.14" => :build
        depends_on "homebrew/core/python@3.14" => :test
        depends_on "python-setuptools"
      end

      expect(described_class.direct_dependency_paths(f)).to eq(
        "python@3.14" => HOMEBREW_PREFIX/"opt/python@3.14/bin/python3.14",
      )
    end

    it "can limit paths to required Python dependencies" do
      f = formula "foo" do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/foo-1.0.tgz"

        depends_on "python@3.13"
        depends_on "python@3.14" => :build
      end

      expect(described_class.direct_dependency_paths(f, required: true)).to eq(
        "python@3.13" => HOMEBREW_PREFIX/"opt/python@3.13/bin/python3.13",
      )
    end
  end

  describe "#major_minor_version" do
    it "returns a Version for Python 2" do
      expect(described_class).to receive(:major_minor_version).and_return(Version)
      described_class.major_minor_version("python")
    end
  end

  describe "#site_packages" do
    it "gives a different location between PyPy and Python 2" do
      expect(described_class.site_packages("python")).not_to eql(described_class.site_packages("pypy"))
    end
  end

  describe "#homebrew_site_packages" do
    it "returns the Homebrew site packages location" do
      expect(described_class).to receive(:site_packages).and_return(Pathname)
      described_class.site_packages("python")
    end
  end

  describe "#user_site_packages" do
    it "can determine user site packages location" do
      expect(described_class).to receive(:user_site_packages).and_return(Pathname)
      described_class.user_site_packages("python")
    end
  end
end
