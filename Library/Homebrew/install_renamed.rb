# typed: strict
# frozen_string_literal: true

# Helper module for installing default files.
module InstallRenamed
  sig {
    params(src: T.any(String, Pathname), new_basename: String,
           _block: T.nilable(T.proc.params(src: Pathname, dst: Pathname).returns(T.nilable(Pathname)))).void
  }
  def install_p(src, new_basename, &_block)
    super do |src, dst|
      if src.directory?
        dst.install(src.children)
        next
      else
        append_default_if_different(src, dst)
      end
    end
  end

  sig {
    params(pattern: T.any(Pathname, String, Regexp), replacement: T.any(Pathname, String),
           _block: T.nilable(T.proc.params(src: Pathname, dst: Pathname).returns(Pathname))).void
  }
  def cp_path_sub(pattern, replacement, &_block)
    super do |src, dst|
      append_default_if_different(src, dst)
    end
  end

  sig { params(other: T.any(String, Pathname)).returns(Pathname) }
  def +(other)
    super.extend(InstallRenamed)
  end

  sig { params(other: T.any(String, Pathname)).returns(Pathname) }
  def /(other)
    super.extend(InstallRenamed)
  end

  private

  sig { params(src: Pathname, dst: Pathname).returns(Pathname) }
  def append_default_if_different(src, dst)
    return dst if !dst.file? || FileUtils.identical?(src, dst)

    # Bottle installs restore config from `<keg>/.bottle/etc` through this
    # helper. If the live config still matches an older bottled default, replace
    # it so untouched configs advance on upgrade. Modified configs still receive
    # the new default as `*.default`.
    src.ascend do |path|
      next if path.basename.to_s != ".bottle" || path.parent.parent.parent != HOMEBREW_CELLAR

      path.parent.parent.subdirs.each do |prefix|
        next if prefix == path.parent

        default_file = prefix/".bottle"/src.relative_path_from(path)
        return dst if default_file.file? && FileUtils.identical?(dst, default_file)
      end

      break
    end

    Pathname.new("#{dst}.default")
  end
end
