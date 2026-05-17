# typed: false
# frozen_string_literal: true

require "cmd/shared_examples/args_parse"
require "cmd/which-formula"

RSpec.describe Homebrew::Cmd::WhichFormula do
  let(:klass) { Homebrew::Cmd::WhichFormula }

  it_behaves_like "parseable arguments"

  describe "which_formula" do
    let(:brew_sh_env) { { "HOMEBREW_COLOR" => nil, "HOMEBREW_NO_EMOJI" => nil } }
    let(:shell_cellar) do
      if (HOMEBREW_LIBRARY_PATH.parent.parent/"Cellar").directory?
        HOMEBREW_LIBRARY_PATH.parent.parent/"Cellar"
      else
        HOMEBREW_CELLAR
      end
    end

    before do
      # Override DATABASE_FILE to use test environment's HOMEBREW_CACHE
      test_db_file = HOMEBREW_CACHE/"api"/klass::ENDPOINT
      stub_const("#{klass}::DATABASE_FILE", test_db_file)

      db = klass::DATABASE_FILE
      db.dirname.mkpath
      db.write(<<~EOS)
        foo(1.0.0):foo2 foo3
        bar(1.2.3):
        baz(10.4):baz
        qux(4.5.6):QUX
        quux:quux
      EOS

      (shell_cellar/"foo/1.0.0").mkpath
    end

    after do
      FileUtils.rm_rf shell_cellar/"foo"
    end

    it "prints plain formula names when outputting to a non-TTY", :integration_test do
      expect { brew_sh "which-formula", "foo2", brew_sh_env }.to output("foo\n").to_stdout
      expect do
        brew_sh "which-formula", "foo2", brew_sh_env.merge("HOMEBREW_NO_EMOJI" => "1")
      end.to output("foo\n").to_stdout
      expect { brew_sh "which-formula", "baz", brew_sh_env }.to output("baz\n").to_stdout
      expect { brew_sh "which-formula", "bar" }.not_to output.to_stdout
      expect { brew_sh "which-formula", "QUX", brew_sh_env }.to output("qux\n").to_stdout
      expect { brew_sh "which-formula", "quux", brew_sh_env }.to output("quux\n").to_stdout
    end

    it "errors if the API is disabled and the executable database is missing", :integration_test do
      klass::DATABASE_FILE.unlink

      expect do
        expect(brew_sh("which-formula", "foo2", "HOMEBREW_NO_INSTALL_FROM_API" => "1")).to be_a_failure
      end.to output(/HOMEBREW_NO_INSTALL_FROM_API must be unset/).to_stderr
    end
  end
end
