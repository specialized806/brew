use crate::BrewResult;
use crate::delegate;
use crate::homebrew;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

pub fn run(args: &[String]) -> BrewResult<ExitCode> {
    if args[1..]
        .iter()
        .any(|arg| arg.starts_with('-') || arg.contains('/'))
    {
        return delegate::run(args);
    }

    let cellar = homebrew::cellar_path()?;
    let prefix = homebrew::prefix_path()?;
    let caskroom = homebrew::caskroom_path()?;

    if args.len() == 1 {
        let formulae = homebrew::installed_names(&cellar)?;
        let casks = homebrew::installed_names(&caskroom)?;
        homebrew::print_sections(&formulae, &casks);
        return Ok(ExitCode::SUCCESS);
    }

    let mut missing = Vec::new();
    let mut listed_any = false;

    for name in &args[1..] {
        match list_formula_paths(&cellar, &prefix, name)? {
            FormulaPaths::Paths(paths) => {
                if listed_any {
                    println!();
                }
                println!("{}", paths.join("\n"));
                listed_any = true;
                continue;
            }
            FormulaPaths::Delegate => return delegate::run(args),
            FormulaPaths::Missing => {}
        }

        if let Some(paths) = list_cask_paths(&caskroom, name)? {
            if listed_any {
                println!();
            }
            println!("{}", paths.join("\n"));
            listed_any = true;
            continue;
        }

        missing.push(name.clone());
    }

    if !missing.is_empty() {
        for name in missing {
            eprintln!("No such keg or cask: {name}");
        }
        return Ok(ExitCode::FAILURE);
    }

    Ok(ExitCode::SUCCESS)
}

enum FormulaPaths {
    Delegate,
    Missing,
    Paths(Vec<String>),
}

fn list_formula_paths(cellar: &Path, prefix: &Path, name: &str) -> BrewResult<FormulaPaths> {
    let rack = cellar.join(name);
    let versions = homebrew::installed_versions(&rack)?;
    if versions.is_empty() {
        return Ok(FormulaPaths::Missing);
    }

    if let Some(prefix) = current_keg_path(prefix, &rack, name)? {
        return list_formula_paths_in(&prefix);
    }

    if versions.len() == 1 {
        return list_formula_paths_in(&rack.join(&versions[0]));
    }

    Ok(FormulaPaths::Delegate)
}

fn current_keg_path(prefix: &Path, rack: &Path, name: &str) -> BrewResult<Option<PathBuf>> {
    for path in [
        prefix.join("opt").join(name),
        prefix.join("var/homebrew/linked").join(name),
    ] {
        let metadata = match fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error.into()),
        };

        if metadata.file_type().is_symlink() && path.is_dir() {
            let resolved = fs::canonicalize(&path)?;
            if resolved.starts_with(rack) {
                return Ok(Some(resolved));
            }
        }
    }

    Ok(None)
}

fn list_formula_paths_in(prefix: &Path) -> BrewResult<FormulaPaths> {
    Ok(FormulaPaths::Paths(list_paths(prefix)?))
}

fn list_cask_paths(caskroom: &Path, name: &str) -> BrewResult<Option<Vec<String>>> {
    let cask_directory = caskroom.join(name);
    if !cask_directory.is_dir() {
        return Ok(None);
    }

    Ok(Some(list_paths(&cask_directory)?))
}

fn list_paths(path: &Path) -> BrewResult<Vec<String>> {
    Ok(homebrew::list_files(path)?
        .into_iter()
        .map(|path| path.display().to_string())
        .collect())
}
