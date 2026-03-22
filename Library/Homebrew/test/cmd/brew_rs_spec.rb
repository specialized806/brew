# frozen_string_literal: true

# This spec exercises brew.sh dispatch rather than a Ruby class API.
# rubocop:disable RSpec/DescribeClass
RSpec.describe "brew-rs" do
  let(:brew_rs_bin) { HOMEBREW_LIBRARY_PATH/"vendor/brew-rs/brew-rs" }
  let(:brew_rs_cache) { Pathname(TEST_TMPDIR)/"brew-rs-cache" }
  let(:brew_rs_runtime_env) do
    {
      "HOMEBREW_BREW_SH"                    => (HOMEBREW_LIBRARY_PATH.parent.parent/"bin/brew").to_s,
      "HOMEBREW_NO_COLOR"                   => "1",
      "HOMEBREW_DEVELOPER"                  => "1",
      "HOMEBREW_EXPERIMENTAL_RUST_FRONTEND" => "1",
    }
  end
  let(:brew_rs_env) { brew_rs_runtime_env.merge("HOMEBREW_CACHE" => brew_rs_cache.to_s) }
  let(:api_cache) { brew_rs_cache/"api" }
  let(:runtime_prefix) { HOMEBREW_LIBRARY_PATH.parent.parent }

  before do
    skip "brew-rs is not built." unless brew_rs_bin.executable?
  end

  after do
    FileUtils.rm_rf brew_rs_cache
  end

  it "uses the brew-rs search flow", :integration_test do
    api_cache.mkpath
    (api_cache/"formula_names.txt").write("testball\n")
    (api_cache/"cask_names.txt").write("local-caffeine\n")

    expect do
      expect { brew_sh "search", "l", brew_rs_env }.to be_a_success
    end.to output(/testball\n\nlocal-caffeine\n/).to_stdout
  end

  it "uses fuzzy search when plain-text search has no exact matches", :integration_test do
    api_cache.mkpath
    (api_cache/"formula_names.txt").write("testball\n")
    (api_cache/"cask_names.txt").write("")

    expect do
      expect { brew_sh "search", "testbal", brew_rs_env }.to be_a_success
    end.to output("testball\n").to_stdout
  end

  it "matches the Ruby info output", :integration_test do
    formula_path = setup_test_formula "testball"

    ruby_env = brew_rs_runtime_env.dup.tap { |env| env.delete("HOMEBREW_EXPERIMENTAL_RUST_FRONTEND") }
    brew_file = brew_rs_runtime_env.fetch("HOMEBREW_BREW_SH")

    ruby_stdout, _ruby_stderr, ruby_status = Open3.capture3(ruby_env, brew_file, "info", formula_path.to_s)
    rust_stdout, rust_stderr, rust_status = Open3.capture3(brew_rs_runtime_env, brew_file, "info", formula_path.to_s)

    expect(ruby_status.success?).to be true
    expect(rust_status.success?).to be true
    expect(rust_stdout).to eq(ruby_stdout)
    expect(Tty.strip_ansi(rust_stderr)).to include("Warning: using the experimental brew-rs Rust frontend.")
  end

  it "uses the brew-rs list flow", :integration_test do
    runtime_cellar = runtime_prefix/"Cellar"
    runtime_caskroom = runtime_prefix/"Caskroom"

    begin
      FileUtils.rm_rf runtime_cellar/"foo"
      FileUtils.rm_rf runtime_caskroom/"local-caffeine"
      (runtime_cellar/"foo/1.0/bin").mkpath
      (runtime_cellar/"foo/1.0/bin/foo").write("foo")
      (runtime_caskroom/"local-caffeine/1.2.3").mkpath

      expect do
        expect { brew_sh "list", brew_rs_runtime_env }.to be_a_success
      end.to output(/foo.*local-caffeine/m).to_stdout
    ensure
      FileUtils.rm_rf runtime_cellar/"foo"
      FileUtils.rm_rf runtime_caskroom/"local-caffeine"
    end
  end

  it "uses the linked keg when listing formula files", :integration_test do
    runtime_cellar = runtime_prefix/"Cellar"
    linked_file = runtime_cellar/"linked-formula/1.0/bin/linked-formula"

    begin
      FileUtils.rm_rf runtime_cellar/"linked-formula"
      FileUtils.rm_f runtime_prefix/"opt/linked-formula"
      (runtime_cellar/"linked-formula/1.0/bin").mkpath
      linked_file.write("foo")
      (runtime_cellar/"linked-formula/2.0/bin").mkpath
      (runtime_cellar/"linked-formula/2.0/bin/linked-formula-newer").write("foo")
      (runtime_prefix/"opt").mkpath
      FileUtils.ln_sf(runtime_cellar/"linked-formula/1.0", runtime_prefix/"opt/linked-formula")

      expect do
        expect { brew_sh "list", "linked-formula", brew_rs_runtime_env }.to be_a_success
      end.to output(%r{linked-formula/1\.0/bin/linked-formula\n\z}).to_stdout
    ensure
      FileUtils.rm_rf runtime_cellar/"linked-formula"
      FileUtils.rm_f runtime_prefix/"opt/linked-formula"
    end
  end
end
# rubocop:enable RSpec/DescribeClass
