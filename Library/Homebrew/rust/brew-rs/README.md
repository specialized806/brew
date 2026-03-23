# brew-rs

`brew-rs` is the opt-in Rust frontend for a small set of `brew` commands.
Today the gated command set is `search`, `info`, `list`, `install`,
`reinstall`, `update`, `upgrade`, and `uninstall`.

Meaningful Rust behavior currently exists for `search` and `list`.
`info` and the mutating commands currently print a warning to `stderr` and
delegate back to the existing Ruby frontend for correctness.

It is intentionally built through `brew vendor-install brew-rs`, which runs
standard Cargo commands under the hood instead of a bespoke build wrapper.

## Pre-step

Export both Rust frontend gate variables before building or running `brew-rs`:

```bash
export HOMEBREW_DEVELOPER=1
export HOMEBREW_EXPERIMENTAL_RUST_FRONTEND=1
```

Before running `rake`, add Homebrew's portable Ruby to `PATH` and install
`rake` there if needed:

```bash
portable_ruby_bindir="$PWD/Library/Homebrew/vendor/portable-ruby/current/bin"
[[ -x "${portable_ruby_bindir}/ruby" ]] || ./bin/brew vendor-install ruby
if [[ ! -x "${portable_ruby_bindir}/rake" ]]
then
  "${portable_ruby_bindir}/gem" install rake --no-document
fi
export PATH="${portable_ruby_bindir}:${PATH}"
```

## Build

```bash
cd Library/Homebrew/rust/brew-rs
rake build
```

## Enable

```bash
./bin/brew search jq
```

The first supported Rust-backed command will run `brew vendor-install brew-rs`
automatically and skip rebuilding when the vendored binary is already up-to-date.
If `cargo` from the `rust` formula is not available yet, `brew` prints a warning
to `stderr` and falls back to the existing Ruby frontend instead of failing.
When `brew-rs` is used, `brew` prints an experimental warning to `stderr`.
If a command is not meaningfully implemented in Rust yet, `brew-rs` also
prints a handoff warning before delegating back to Ruby.

## Rust Checks

```bash
cd Library/Homebrew/rust/brew-rs
rake check
```

## Homebrew Checks

```bash
HOMEBREW_NO_AUTO_UPDATE=1 ./bin/brew tests --only=cmd/brew_rs --no-parallel
HOMEBREW_NO_AUTO_UPDATE=1 ./bin/brew typecheck
HOMEBREW_NO_AUTO_UPDATE=1 ./bin/brew lgtm
```

The `cmd/brew_rs` integration spec is intentionally small because integration
tests are slow. It currently covers the Rust-owned `search` and `list` flows.

## Benchmark

The `benchmark` task compares the Ruby and Rust frontends with `hyperfine` for
the commands currently gated through `brew-rs`.

`rake` should be run with Homebrew's portable Ruby bin directory at the front
of `PATH`. The benchmark prints the normal `hyperfine` output along with each
command's stdout/stderr. Outside the default Homebrew prefix it benchmarks
`search`, `info`, and `list`, then skips `install`, `reinstall`, `upgrade`,
`uninstall`, and `update`. On a default-prefix Tier 1 install it runs the
write benchmarks for real.

Right now only `search` and `list` do meaningful work in Rust. The `info`
benchmark measures Rust dispatch plus an immediate handoff back to Ruby, and
the mutating-command benchmarks do the same for the existing Ruby/Bash install
path. If the vendored binary is missing, the benchmark task builds it first
with `vendor-install`.

```bash
brew install hyperfine
cd Library/Homebrew/rust/brew-rs
rake benchmark
```

## Tier 1 Smoke Test

Run these on a default-prefix Tier 1 Homebrew install outside this repository checkout:

```bash
brew install hello
brew reinstall hello
brew upgrade hello
brew uninstall hello
brew update --quiet --force
```

## Next Steps

The current plan is to keep correctness-sensitive install lifecycle work in
Ruby while moving the heavy bottle path into Rust in small slices.

- Keep `brew.sh` as a thin gate and dispatch layer.
- Keep using existing Homebrew paths, caches, and metadata formats.
- Move more read-only behavior into Rust when it produces clear wins.
- For formula installs, move bottle fetch and pour into Rust first.
- Keep `post_install` and the more involved finish/finalization steps in Ruby
  until narrower shared helpers exist and profiling shows a clear benefit to
  moving more of that logic.
