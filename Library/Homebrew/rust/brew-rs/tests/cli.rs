use std::ffi::OsString;
use std::fs;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::process;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

struct TestContext {
    _tempdir: TestDir,
    brew_file: PathBuf,
    cache: PathBuf,
    cellar: PathBuf,
    caskroom: PathBuf,
    prefix: PathBuf,
}

impl TestContext {
    fn new() -> Self {
        let tempdir = new_tempdir();
        let temp_root = tempdir.path().to_path_buf();
        let repo_root = repo_root();
        let prefix = temp_root.join("prefix");
        let brew_file = prefix.join("bin/brew");

        fs::create_dir_all(brew_file.parent().unwrap()).unwrap();
        fs::copy(repo_root.join("bin/brew"), &brew_file).unwrap();
        symlink(repo_root.join("Library"), prefix.join("Library")).unwrap();

        Self {
            _tempdir: tempdir,
            brew_file,
            cache: temp_root.join("cache"),
            cellar: prefix.join("Cellar"),
            caskroom: prefix.join("Caskroom"),
            prefix,
        }
    }

    fn formula_path(&self) -> PathBuf {
        let path = self.prefix.join("rust-parity-testball.rb");
        fs::write(
            &path,
            r#"
class RustParityTestball < Formula
  desc "Rust parity fixture"
  homepage "https://brew.sh"
  url "https://example.com/rust-parity-testball-1.0.tar.gz"
  sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
end
"#
            .trim_start(),
        )
        .unwrap();
        path
    }

    fn ruby_command(&self) -> Command {
        let mut command = Command::new(&self.brew_file);
        command.current_dir(repo_root());
        for (key, value) in self.common_env() {
            command.env(key, value);
        }
        command
    }

    fn rust_command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_brew-rs"));
        command.current_dir(repo_root());
        for (key, value) in self.common_env() {
            command.env(key, value);
        }
        command
    }

    fn common_env(&self) -> [(OsString, OsString); 9] {
        [
            (
                "HOMEBREW_BREW_FILE".into(),
                self.brew_file.clone().into_os_string(),
            ),
            ("HOMEBREW_CACHE".into(), self.cache.clone().into_os_string()),
            (
                "HOMEBREW_CASKROOM".into(),
                self.caskroom.clone().into_os_string(),
            ),
            (
                "HOMEBREW_CELLAR".into(),
                self.cellar.clone().into_os_string(),
            ),
            ("HOMEBREW_DEVELOPER".into(), OsString::from("1")),
            ("HOMEBREW_NO_AUTO_UPDATE".into(), OsString::from("1")),
            ("HOMEBREW_NO_COLOR".into(), OsString::from("1")),
            ("HOMEBREW_NO_ENV_HINTS".into(), OsString::from("1")),
            (
                "HOMEBREW_PREFIX".into(),
                self.prefix.clone().into_os_string(),
            ),
        ]
    }
}

#[test]
fn search_uses_the_rust_search_flow() {
    let context = TestContext::new();
    let api_cache = context.cache.join("api");

    fs::create_dir_all(&api_cache).unwrap();
    fs::write(api_cache.join("formula_names.txt"), "testball\n").unwrap();
    fs::write(api_cache.join("cask_names.txt"), "local-caffeine\n").unwrap();

    let output = context
        .rust_command()
        .args(["search", "l"])
        .output()
        .unwrap();

    assert!(output.status.success());
    assert_eq!(
        String::from_utf8(output.stdout).unwrap(),
        "testball\n\nlocal-caffeine\n"
    );
}

#[test]
fn search_uses_fuzzy_fallback_when_plain_text_search_has_no_exact_matches() {
    let context = TestContext::new();
    let api_cache = context.cache.join("api");

    fs::create_dir_all(&api_cache).unwrap();
    fs::write(api_cache.join("formula_names.txt"), "testball\n").unwrap();
    fs::write(api_cache.join("cask_names.txt"), "").unwrap();

    let output = context
        .rust_command()
        .args(["search", "testbal"])
        .output()
        .unwrap();

    assert!(output.status.success());
    assert_eq!(String::from_utf8(output.stdout).unwrap(), "testball\n");
}

#[test]
fn info_matches_the_ruby_backend_output() {
    let context = TestContext::new();
    let formula = context.formula_path();

    let ruby_output = context
        .ruby_command()
        .args(["info", formula.to_str().unwrap()])
        .output()
        .unwrap();
    let rust_output = context
        .rust_command()
        .args(["info", formula.to_str().unwrap()])
        .output()
        .unwrap();

    assert!(ruby_output.status.success());
    assert!(rust_output.status.success());
    assert_eq!(rust_output.stdout, ruby_output.stdout);
    assert!(
        String::from_utf8(rust_output.stderr)
            .unwrap()
            .contains("Warning: brew-rs is handing info back to the Ruby backend.")
    );
}

#[test]
fn list_matches_the_ruby_backend_output_for_named_formula() {
    let context = TestContext::new();

    fs::create_dir_all(context.cellar.join("foo/1.0/bin")).unwrap();
    fs::write(context.cellar.join("foo/1.0/bin/foo"), "foo").unwrap();

    let ruby_output = context
        .ruby_command()
        .args(["list", "foo"])
        .output()
        .unwrap();
    let rust_output = context
        .rust_command()
        .args(["list", "foo"])
        .output()
        .unwrap();

    assert!(ruby_output.status.success());
    assert!(rust_output.status.success());
    assert_eq!(rust_output.stdout, ruby_output.stdout);
}

#[test]
fn list_uses_the_linked_keg_when_listing_formula_files() {
    let context = TestContext::new();
    let linked_keg = context.cellar.join("linked-formula/1.0");

    fs::create_dir_all(linked_keg.join("bin")).unwrap();
    fs::write(linked_keg.join("bin/linked-formula"), "foo").unwrap();
    fs::create_dir_all(context.cellar.join("linked-formula/2.0/bin")).unwrap();
    fs::write(
        context
            .cellar
            .join("linked-formula/2.0/bin/linked-formula-newer"),
        "foo",
    )
    .unwrap();
    fs::create_dir_all(context.prefix.join("opt")).unwrap();
    symlink(&linked_keg, context.prefix.join("opt/linked-formula")).unwrap();

    let ruby_output = context
        .ruby_command()
        .args(["list", "linked-formula"])
        .output()
        .unwrap();
    let rust_output = context
        .rust_command()
        .args(["list", "linked-formula"])
        .output()
        .unwrap();

    assert!(ruby_output.status.success());
    assert!(rust_output.status.success());
    assert_eq!(rust_output.stdout, ruby_output.stdout);
}

fn new_tempdir() -> TestDir {
    let root = repo_root().join("tmp");
    fs::create_dir_all(&root).unwrap();
    TestDir::new_in(&root)
}

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../..")
        .canonicalize()
        .unwrap()
}

struct TestDir(PathBuf);

impl TestDir {
    fn new_in(root: &Path) -> Self {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let path = root.join(format!(
            "brew-rs-cli-{}-{}-{}",
            process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
