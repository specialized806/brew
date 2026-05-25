# typed: false
# frozen_string_literal: true

require "install_steps"

RSpec.describe Homebrew::InstallSteps do
  let(:root) { Pathname(TEST_TMPDIR)/"install-steps" }
  let(:context) do
    root_path = root
    Class.new do
      define_method(:prefix) { root_path/"prefix" }
      define_method(:var) { root_path/"var" }
      define_method(:staged_path) { root_path/"stage" }
    end.new
  end

  before do
    FileUtils.rm_rf root
  end

  after do
    FileUtils.rm_rf root
  end

  specify "runs mkdir, touch, move and symlink steps", :aggregate_failures do
    steps = Homebrew::InstallSteps::DSL.build(default_base: :var, default_source_base: :staged_path,
                                              default_target_base: :staged_path) do
      mkdir_p "log/example"
      touch "state/marker", base: :prefix
      mv "move-source", "move-target"
      ln_s "move-target", "linked-target", source_base: :relative
    end

    (root/"stage").mkpath
    (root/"stage/move-source").write "moved"

    Homebrew::InstallSteps::Runner.new(context:).run(steps)

    expect(root/"var/log/example").to be_a_directory
    expect(root/"prefix/state/marker").to exist
    expect(root/"stage/move-target").to exist
    expect(root/"stage/linked-target").to be_a_symlink
    expect((root/"stage/linked-target").readlink).to eq(Pathname("move-target"))
  end

  specify "runs mkdir without creating parent directories" do
    steps = Homebrew::InstallSteps::DSL.build(default_base: :var) do
      mkdir "missing-parent/example"
    end

    expect(steps).to include(
      "type" => "mkdir",
      "path" => {
        "base" => "var",
        "path" => "missing-parent/example",
      },
    )
    expect { Homebrew::InstallSteps::Runner.new(context:).run(steps) }.to raise_error(Errno::ENOENT)
  end

  specify "runs mkdir_p recursively" do
    steps = Homebrew::InstallSteps::DSL.build(default_base: :var) do
      mkdir_p "nested/example"
    end

    expect(steps).to include(
      "type" => "mkdir_p",
      "path" => {
        "base" => "var",
        "path" => "nested/example",
      },
    )

    Homebrew::InstallSteps::Runner.new(context:).run(steps)

    expect(root/"var/nested/example").to be_a_directory
  end

  specify "does not add the default base to home paths" do
    steps = Homebrew::InstallSteps::DSL.build(default_base: :var) do
      mkdir_p "~/example"
    end

    expect(steps).to contain_exactly(
      "type" => "mkdir_p",
      "path" => {
        "path" => "~/example",
      },
    )
  end

  specify "moves a directory's children without moving the new target directory" do
    steps = Homebrew::InstallSteps::DSL.build(default_source_base: :staged_path, default_target_base: :staged_path) do
      move_children ".", "Nested"
    end

    (root/"stage").mkpath
    (root/"stage/source-file").write "source"

    Homebrew::InstallSteps::Runner.new(context:).run(steps)

    expect(root/"stage/Nested/source-file").to exist
  end

  specify "removes symlinks marked for uninstall" do
    steps = Homebrew::InstallSteps::DSL.build(default_target_base: :staged_path) do
      ln_sf "target", "linked-target", source_base: :relative, uninstall: true
    end

    (root/"stage").mkpath
    File.symlink "target", root/"stage/linked-target"

    Homebrew::InstallSteps::Runner.new(context:).run(steps, phase: :uninstall)

    expect(root/"stage/linked-target").not_to be_a_symlink
  end

  specify "does not expose the surrounding formula or cask DSL" do
    expect do
      Homebrew::InstallSteps::DSL.build(default_base: :var) do
        system "true"
      end
    end.to raise_error(NameError)
  end
end
