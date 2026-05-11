# typed: strict
# frozen_string_literal: true

require "test_bot"

RSpec.describe Homebrew::TestBot::Formulae do
  describe "#dependency_name_match?" do
    it "requires exact matches when either name is tap-qualified", :aggregate_failures do
      Dir.mktmpdir do |tmpdir|
        output_paths = {
          bottle:                     Pathname.new("#{tmpdir}/bottle.txt"),
          linkage:                    Pathname.new("#{tmpdir}/linkage.txt"),
          skipped_or_failed_formulae: Pathname.new("#{tmpdir}/skipped.txt"),
        }
        formulae = described_class.new(
          tap: nil, git: "git", dry_run: true, fail_fast: false, verbose: false,
          output_paths:
        )

        expect(formulae.send(:dependency_name_match?, Dependency.new("foo"), "foo")).to be(true)
        expect(formulae.send(:dependency_name_match?, Dependency.new("homebrew/core/foo"), "homebrew/core/foo"))
          .to be(true)
        expect(formulae.send(:dependency_name_match?, Dependency.new("homebrew/core/foo"), "foo")).to be(false)
        expect(formulae.send(:dependency_name_match?, Dependency.new("homebrew/core/foo"), "user/tap/foo"))
          .to be(false)
      end
    end
  end

  describe "#annotate_added_dependencies" do
    it "writes a warning annotation for the new recursive dependency impact" do
      T.bind(self, T.untyped)

      formula = formula("foo") do
        url "foo-1.0"
        depends_on "existing"
        depends_on "bar"
      end
      existing = formula("existing") { url "existing-1.0" }
      bar = formula("bar") do
        url "bar-1.0"
        depends_on "existing"
        depends_on "baz"
      end
      baz = formula("baz") { url "baz-1.0" }

      [existing, bar, baz].each { |f| stub_formula_loader f }
      [[bar, 1_000_000], [baz, 500_000]].each do |f, size|
        allow(f).to receive(:bottle_for_tag)
          .and_return(instance_double(Bottle, fetch_tab: nil, installed_size: size))
      end
      allow(Utils).to receive(:safe_popen_read).and_return <<~DIFF
        @@ -2,0 +7,1 @@
        +  depends_on "bar"
      DIFF

      Dir.mktmpdir do |tmpdir|
        output_paths = {
          bottle:                     Pathname.new("#{tmpdir}/bottle.txt"),
          linkage:                    Pathname.new("#{tmpdir}/linkage.txt"),
          skipped_or_failed_formulae: Pathname.new("#{tmpdir}/skipped.txt"),
        }
        formulae = described_class.new(
          tap: nil, git: "git", dry_run: true, fail_fast: false, verbose: false,
          output_paths:
        )

        with_env(GITHUB_ACTIONS: "true") do
          expect { formulae.send(:annotate_added_dependencies, formula) }
            .to output(
              "::warning file=#{formula.path.relative_path_from(CoreTap.instance.path)},line=7," \
              "title=foo: new dependency impact::Adding `bar` adds 2 new recursive dependencies " \
              "on #{Utils::Bottles.tag} (1.5MB).\n",
            ).to_stdout
        end
      end
    end
  end

  describe "#testing_portable_ruby?" do
    it "returns false (not nil) when tap is nil" do
      # Regression test: without `!!`, tap&.core_tap? returns nil when tap is nil,
      # and `nil && ...` evaluates to nil, violating the T::Boolean return type.
      Dir.mktmpdir do |tmpdir|
        output_paths = {
          bottle:                     Pathname.new("#{tmpdir}/bottle.txt"),
          linkage:                    Pathname.new("#{tmpdir}/linkage.txt"),
          skipped_or_failed_formulae: Pathname.new("#{tmpdir}/skipped.txt"),
        }
        formulae = described_class.new(
          tap: nil, git: "git", dry_run: true, fail_fast: false, verbose: false,
          output_paths:
        )

        result = formulae.send(:testing_portable_ruby?)
        expect(result).to be(false)
      end
    end
  end

  describe "#verify_local_bottles" do
    it "returns false (not nil) when testing portable ruby" do
      # Regression test: the early return for portable ruby must be `return false`,
      # not bare `return` (which returns nil), to satisfy the T::Boolean return type.
      Dir.mktmpdir do |tmpdir|
        output_paths = {
          bottle:                     Pathname.new("#{tmpdir}/bottle.txt"),
          linkage:                    Pathname.new("#{tmpdir}/linkage.txt"),
          skipped_or_failed_formulae: Pathname.new("#{tmpdir}/skipped.txt"),
        }
        formulae = described_class.new(
          tap: CoreTap.instance, git: "git", dry_run: true, fail_fast: false, verbose: false,
          output_paths:
        )
        formulae.testing_formulae = ["portable-ruby"]

        result = formulae.send(:verify_local_bottles)
        expect(result).to be(false)
      end
    end
  end
end
