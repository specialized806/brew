# typed: strict
# frozen_string_literal: true

require "test_bot"

RSpec.describe Homebrew::TestBot::Formulae do
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

  describe "#cleanup_bottle_etc_var" do
    it "restores bottled config with InstallRenamed handling" do
      Dir.mktmpdir do |tmpdir|
        formula_class = Class.new(Formula)
        T.unsafe(formula_class).url "foo-2.0"
        T.unsafe(formula_class).version "2.0"
        f = formula_class.new("test-bot-config", Formulary.core_path("test-bot-config"), :stable)
        config_file = HOMEBREW_PREFIX/"etc/test-bot-config.conf"
        default_config_file = Pathname.new("#{config_file}.default")
        old_default_file = f.rack/"1.0/.bottle/etc/test-bot-config.conf"
        new_default_file = f.bottle_prefix/"etc/test-bot-config.conf"

        begin
          FileUtils.rm_rf f.rack
          FileUtils.rm_f config_file
          FileUtils.rm_f default_config_file

          old_default_file.dirname.mkpath
          old_default_file.write "old\n"
          new_default_file.dirname.mkpath
          new_default_file.write "new\n"
          config_file.dirname.mkpath
          config_file.write "old\n"

          described_class.new(
            tap: nil, git: "git", dry_run: true, fail_fast: false, verbose: false,
            output_paths: {
              bottle:                     Pathname.new("#{tmpdir}/bottle.txt"),
              linkage:                    Pathname.new("#{tmpdir}/linkage.txt"),
              skipped_or_failed_formulae: Pathname.new("#{tmpdir}/skipped.txt"),
            }
          ).send(:cleanup_bottle_etc_var, f)

          expect([config_file.read, default_config_file.exist?]).to eq(["new\n", false])
        ensure
          FileUtils.rm_rf f.rack
          FileUtils.rm_f config_file
          FileUtils.rm_f default_config_file
        end
      end
    end
  end
end
