use crate::BrewResult;
use crate::commands::fetch::{self, BottleFetch, FormulaJson, Resolution, ResolvedBottle};
use crate::delegate;
use crate::homebrew;
use crate::utils::formatter;
use anyhow::{Context, anyhow, bail};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

pub fn run(args: &[String]) -> BrewResult<ExitCode> {
    if args.len() != 2 {
        return delegate::run_with_reason(
            args,
            "install",
            "only a single simple named formula argument is supported.",
        );
    }
    if args[1].starts_with('-') {
        return delegate::run_with_reason(args, "install", "flags are not yet supported.");
    }
    if !fetch::is_simple_formula_name(&args[1]) {
        return delegate::run_with_reason(
            args,
            "install",
            "only a single simple named formula argument is supported.",
        );
    }

    let api_cache = homebrew::cache_api_path()?;
    let aliases = fetch::load_aliases(&api_cache.join("formula_aliases.txt"))?;
    let bottle_tag = fetch::current_bottle_tag()?;
    let client = fetch::build_client()?;
    let mut signed_cache_formulae = None;

    let resolved = match fetch::resolve_bottle(
        &args[1],
        &aliases,
        &api_cache,
        &mut signed_cache_formulae,
        &bottle_tag,
        &client,
    )? {
        Resolution::Bottle(resolved) => resolved,
        Resolution::Delegate(reason) => return delegate::run_with_reason(args, "install", &reason),
    };

    if let Some(reason) = basic_install_delegate_reason(&resolved)? {
        return delegate::run_with_reason(args, "install", &reason);
    }

    // TODO: Add argument parity for multi-formula installs, local formula paths, taps, and flags.
    // TODO: Add `FormulaInstaller#check_install_sanity`, locking, and conflict checks before mutating the Cellar.
    // TODO: Add dependency resolution and installation instead of requiring a leaf bottle formula.
    // TODO: Add relocation and dynamic linkage handling for bottles that are not `:any_skip_relocation`.
    // TODO: Add `post_install`, `Tab` writes, SBOM writes, services, caveats, and global post-install hooks.
    // TODO: Replace the temporary Ruby `brew link` reuse with Rust parity for `Keg#link`.
    // TODO: Validate bottle archive entries before extraction instead of trusting `tar` to keep paths contained.

    fetch::fetch_bottles(std::slice::from_ref(&resolved.bottle), &client)?;
    pour_bottle(&resolved)?;
    link_installed_keg(&resolved.formula.name)
}

fn basic_install_delegate_reason(resolved: &ResolvedBottle) -> BrewResult<Option<String>> {
    let formula = &resolved.formula;

    if !formula.dependencies.is_empty()
        || !formula.build_dependencies.is_empty()
        || !formula.test_dependencies.is_empty()
        || !formula.recommended_dependencies.is_empty()
        || !formula.optional_dependencies.is_empty()
        || !formula.uses_from_macos.is_empty()
    {
        return Ok(Some(format!("`{}` has dependencies.", formula.full_name)));
    }

    match formula.post_install_defined {
        Some(false) => {}
        Some(true) => {
            return Ok(Some(format!(
                "`{}` defines `post_install`.",
                formula.full_name
            )));
        }
        None => {
            return Ok(Some(format!(
                "`{}` is missing install metadata for `post_install`.",
                formula.full_name
            )));
        }
    }

    if !matches!(
        resolved.bottle.bottle_cellar.as_deref(),
        Some("any_skip_relocation" | ":any_skip_relocation")
    ) {
        return Ok(Some(format!(
            "`{}` requires bottle relocation support.",
            formula.full_name
        )));
    }

    if formula.keg_only_reason.is_some() {
        return Ok(Some(format!("`{}` is keg-only.", formula.full_name)));
    }

    if formula.service.is_some() {
        return Ok(Some(format!(
            "`{}` defines service files.",
            formula.full_name
        )));
    }

    if formula
        .caveats
        .as_deref()
        .is_some_and(|caveats| !caveats.trim().is_empty())
    {
        return Ok(Some(format!("`{}` defines caveats.", formula.full_name)));
    }

    let rack = homebrew::cellar_path()?.join(&formula.name);
    if rack.exists() {
        return Ok(Some(format!(
            "reinstalls and upgrades for `{}` are not yet supported.",
            formula.full_name
        )));
    }

    let prefix = homebrew::prefix_path()?;
    if path_exists_or_is_symlink(&prefix.join("opt").join(&formula.name))?
        || path_exists_or_is_symlink(&prefix.join("var/homebrew/linked").join(&formula.name))?
    {
        return Ok(Some(format!(
            "`{}` already has linked install state.",
            formula.full_name
        )));
    }

    Ok(None)
}

fn path_exists_or_is_symlink(path: &Path) -> BrewResult<bool> {
    Ok(path.exists()
        || fs::symlink_metadata(path)
            .map(|metadata| metadata.file_type().is_symlink())
            .unwrap_or(false))
}

fn pour_bottle(resolved: &ResolvedBottle) -> BrewResult<()> {
    let cellar = homebrew::cellar_path()?;
    let rack = cellar.join(&resolved.formula.name);
    let formula_prefix = installed_prefix(&resolved.formula)?;
    let staging_root = cellar.join(format!(
        ".brew-rs-pour-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .context("System clock is before the Unix epoch")?
            .as_nanos()
    ));

    let result = (|| {
        fs::create_dir_all(&cellar)
            .with_context(|| format!("Failed to create {}", cellar.display()))?;
        fs::create_dir(&staging_root)
            .with_context(|| format!("Failed to create {}", staging_root.display()))?;

        formatter::ohai(format!("Pouring {}", display_bottle_basename(&resolved.bottle)?).as_str());

        let status = Command::new("tar")
            .arg("--extract")
            .arg("--no-same-owner")
            .arg("--file")
            .arg(&resolved.bottle.cached_download)
            .arg("--directory")
            .arg(&staging_root)
            .status()
            .with_context(|| {
                format!(
                    "Failed to extract {}",
                    resolved.bottle.cached_download.display()
                )
            })?;
        if !status.success() {
            bail!(
                "Failed to extract {}",
                resolved.bottle.cached_download.display()
            );
        }

        let staged_prefix = staging_root
            .join(&resolved.formula.name)
            .join(fetch::pkg_version(
                &resolved.formula.versions.stable,
                resolved.formula.revision,
            ));
        if !staged_prefix.is_dir() {
            bail!(
                "Bottle {} did not extract {}",
                resolved.bottle.formula_name,
                formula_prefix.display()
            );
        }

        fs::create_dir_all(&rack)
            .with_context(|| format!("Failed to create {}", rack.display()))?;
        fs::rename(&staged_prefix, &formula_prefix).with_context(|| {
            format!(
                "Failed to move {} to {}",
                staged_prefix.display(),
                formula_prefix.display()
            )
        })?;
        remove_install_metadata(&formula_prefix)?;
        fs::remove_dir_all(&staging_root)
            .with_context(|| format!("Failed to remove {}", staging_root.display()))?;

        Ok(())
    })();

    if result.is_err() {
        cleanup_failed_pour(&formula_prefix, &staging_root)?;
    }

    result
}

fn installed_prefix(formula: &FormulaJson) -> BrewResult<PathBuf> {
    Ok(homebrew::cellar_path()?
        .join(&formula.name)
        .join(fetch::pkg_version(
            &formula.versions.stable,
            formula.revision,
        )))
}

fn display_bottle_basename(bottle: &BottleFetch) -> BrewResult<String> {
    let file_name = bottle
        .cached_download
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| anyhow!("Missing bottle filename for {}", bottle.formula_name))?;

    Ok(file_name
        .split_once("--")
        .map(|(_, basename)| basename.to_string())
        .unwrap_or_else(|| file_name.to_string()))
}

fn remove_install_metadata(formula_prefix: &Path) -> BrewResult<()> {
    for metadata_name in ["INSTALL_RECEIPT.json", "sbom.spdx.json"] {
        let metadata_path = formula_prefix.join(metadata_name);
        if metadata_path.exists() {
            fs::remove_file(&metadata_path)
                .with_context(|| format!("Failed to remove {}", metadata_path.display()))?;
        }
    }

    Ok(())
}

fn cleanup_failed_pour(formula_prefix: &Path, staging_root: &Path) -> BrewResult<()> {
    if formula_prefix.exists() {
        fs::remove_dir_all(formula_prefix)
            .with_context(|| format!("Failed to remove {}", formula_prefix.display()))?;
    }

    if staging_root.exists() {
        fs::remove_dir_all(staging_root)
            .with_context(|| format!("Failed to remove {}", staging_root.display()))?;
    }

    if let Some(rack) = formula_prefix.parent() {
        let _ = fs::remove_dir(rack);
    }

    Ok(())
}

fn link_installed_keg(formula_name: &str) -> BrewResult<ExitCode> {
    let status = Command::new(homebrew::brew_file()?)
        .arg("link")
        .arg(formula_name)
        .env_remove("HOMEBREW_EXPERIMENTAL_RUST_FRONTEND")
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .context("Failed to run `brew link`")?;

    Ok(ExitCode::from(
        status.code().unwrap_or(1).clamp(0, 255) as u8
    ))
}
