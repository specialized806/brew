use crate::BrewResult;
use crate::delegate;
use crate::fetch::{self, FormulaJson};
use crate::global;
use crate::utils::formatter;
use crate::utils::tty;
use serde_json::Value;
use std::fs;
use std::io::{self, IsTerminal};
use std::path::Path;
use std::process::ExitCode;

pub fn run(args: &[String]) -> BrewResult<ExitCode> {
    if args.len() != 2 || args[1].starts_with('-') || !fetch::is_simple_formula_name(&args[1]) {
        return delegate::run_with_reason(
            args,
            "info",
            "only a single simple named formula argument is supported.",
        );
    }

    let api_cache = global::cache_api_path()?;
    let aliases = fetch::load_aliases(&api_cache.join("formula_aliases.txt"))?;
    let client = fetch::build_client()?;
    let mut signed_cache_formulae = None;

    let resolved_name = aliases
        .get(&args[1])
        .map(String::as_str)
        .unwrap_or(&args[1]);

    let Some(formula) = fetch::load_formula_json(
        resolved_name,
        &api_cache,
        &mut signed_cache_formulae,
        &client,
    )?
    else {
        return delegate::run_with_reason(
            args,
            "info",
            &format!(
                "formula metadata for `{}` is not available in the Homebrew API cache.",
                args[1]
            ),
        );
    };

    let cellar = global::cellar_path()?;
    let installed_kegs = {
        let keg_dir = cellar.join(&formula.name);
        if keg_dir.is_dir() {
            global::installed_versions(&keg_dir).unwrap_or_default()
        } else {
            Vec::new()
        }
    };

    info_formula(&formula, &installed_kegs);
    Ok(ExitCode::SUCCESS)
}

fn info_formula(formula: &FormulaJson, installed_kegs: &[String]) {
    let tty = io::stdout().is_terminal();

    let mut spec_str = format!("stable {}", formula.versions.stable);
    if formula.versions.bottle.unwrap_or(false) {
        spec_str.push_str(" (bottled)");
    }
    if formula.versions.head.is_some() {
        spec_str.push_str(", HEAD");
    }

    let name_color = if installed_kegs.is_empty() {
        tty::red()
    } else {
        tty::green()
    };
    let name_display = if tty {
        format!(
            "{name_color}{name}{reset}",
            name = formula.full_name,
            reset = tty::reset()
        )
    } else {
        formula.full_name.clone()
    };

    let keg_only_attr = if formula.keg_only.unwrap_or(false) {
        " [keg-only]"
    } else {
        ""
    };

    formatter::ohai(&format!("{name_display}: {spec_str}{keg_only_attr}"));

    if let Some(desc) = &formula.desc {
        println!("{desc}");
    }
    if let Some(homepage) = &formula.homepage {
        formatter_url(homepage, tty);
    }

    if formula.disabled.unwrap_or(false) {
        let reason = formula.disable_reason.as_deref().unwrap_or("is disabled");
        let date = formula
            .disable_date
            .as_deref()
            .map(|d| format!(" on {d}"))
            .unwrap_or_default();
        println!("Disabled because it {reason}{date}!");
    } else if formula.deprecated.unwrap_or(false) {
        let reason = formula
            .deprecation_reason
            .as_deref()
            .unwrap_or("is deprecated");
        let date = formula
            .deprecation_date
            .as_deref()
            .map(|d| format!(" on {d}"))
            .unwrap_or_default();
        println!("Deprecated because it {reason}{date}!");
    }

    if !formula.conflicts_with.is_empty() {
        println!("Conflicts with:");
        for (i, name) in formula.conflicts_with.iter().enumerate() {
            match formula
                .conflicts_with_reasons
                .get(i)
                .and_then(|r| r.as_deref())
            {
                Some(reason) => println!("  {name} (because {reason})"),
                None => println!("  {name}"),
            }
        }
    }

    if installed_kegs.is_empty() {
        println!("Not installed");
    } else {
        println!("Installed");
        let cellar = global::cellar_path().ok();
        let linked_version = cellar.as_ref().and_then(|c| {
            let opt_link = global::prefix_path().ok()?.join("opt").join(&formula.name);
            let target = fs::read_link(&opt_link).ok()?;
            let resolved = if target.is_relative() {
                opt_link.parent()?.join(&target)
            } else {
                target
            };
            let canonical = fs::canonicalize(&resolved).ok()?;
            if canonical.starts_with(c.join(&formula.name)) {
                canonical
                    .file_name()
                    .map(|v| v.to_string_lossy().into_owned())
            } else {
                None
            }
        });
        for version in installed_kegs {
            let star = if linked_version.as_deref() == Some(version.as_str()) {
                " *"
            } else {
                ""
            };
            if let Some(ref c) = cellar {
                let keg = c.join(&formula.name).join(version);
                println!("{} ({}){star}", keg.display(), disk_usage_readable(&keg));
            } else {
                println!("{version}{star}");
            }
        }
    }

    if let Some(source_path) = &formula.ruby_source_path {
        print!("From: ");
        formatter_url(
            &format!("https://github.com/Homebrew/homebrew-core/blob/HEAD/{source_path}"),
            tty,
        );
    }

    if let Some(license) = &formula.license {
        println!("License: {license}");
    }

    let dep_line = |deps: &[Value]| -> Vec<String> {
        deps.iter()
            .filter_map(|dep| match dep {
                Value::String(s) => Some(s.clone()),
                Value::Object(map) => map.get("name").and_then(Value::as_str).map(String::from),
                _ => None,
            })
            .collect()
    };
    let build = dep_line(&formula.build_dependencies);
    let required = dep_line(&formula.dependencies);
    let recommended = dep_line(&formula.recommended_dependencies);
    let optional = dep_line(&formula.optional_dependencies);
    if !build.is_empty() || !required.is_empty() || !recommended.is_empty() || !optional.is_empty()
    {
        formatter::ohai("Dependencies");
        for (label, deps) in [
            ("Build", &build),
            ("Required", &required),
            ("Recommended", &recommended),
            ("Optional", &optional),
        ] {
            if !deps.is_empty() {
                println!("{label}: {}", deps.join(", "));
            }
        }
    }

    if formula.versions.head.is_some() {
        formatter::ohai("Options");
        println!("--HEAD");
        println!("\tInstall HEAD version");
    }

    if let Some(caveats) = &formula.caveats {
        formatter::ohai("Caveats");
        println!("{caveats}");
    }

    if let Some(Value::Object(analytics_map)) = &formula.analytics {
        formatter::ohai("Analytics");
        for (key, label) in [
            ("install", "install"),
            ("install_on_request", "install-on-request"),
            ("build_error", "build-error"),
        ] {
            let Some(Value::Object(periods)) = analytics_map.get(key) else {
                continue;
            };
            let parts: Vec<String> = [("30d", "30 days"), ("90d", "90 days"), ("365d", "365 days")]
                .iter()
                .filter_map(|(k, display)| {
                    let Value::Object(counts) = periods.get(*k)? else {
                        return None;
                    };
                    let total: i64 = counts.values().filter_map(Value::as_i64).sum();
                    Some(format!("{} ({display})", number_readable(total)))
                })
                .collect();
            if !parts.is_empty() {
                println!("{label}: {}", parts.join(", "));
            }
        }
    }
}

fn formatter_url(url: &str, tty: bool) {
    if tty {
        println!(
            "{underline}{url}{reset}",
            underline = tty::underline(),
            reset = tty::reset()
        );
    } else {
        println!("{url}");
    }
}

fn disk_usage_readable(path: &Path) -> String {
    let bytes: u64 = walkdir::WalkDir::new(path)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_file())
        .filter_map(|e| e.metadata().ok())
        .map(|m| m.len())
        .sum();
    const KB: u64 = 1_000;
    const MB: u64 = 1_000_000;
    const GB: u64 = 1_000_000_000;
    match bytes {
        b if b >= GB => format!("{:.1}GB", b as f64 / GB as f64),
        b if b >= MB => format!("{:.1}MB", b as f64 / MB as f64),
        b if b >= KB => format!("{:.1}KB", b as f64 / KB as f64),
        b => format!("{b}B"),
    }
}

fn number_readable(n: i64) -> String {
    let s = n.abs().to_string();
    let mut result = String::with_capacity(s.len() + s.len() / 3);
    for (i, ch) in s.chars().enumerate() {
        if i > 0 && (s.len() - i) % 3 == 0 {
            result.push(',');
        }
        result.push(ch);
    }
    if n < 0 { format!("-{result}") } else { result }
}

#[cfg(test)]
mod tests {
    use super::number_readable;

    #[test]
    fn formats_numbers_with_comma_separators() {
        assert_eq!(number_readable(0), "0");
        assert_eq!(number_readable(999), "999");
        assert_eq!(number_readable(1_000), "1,000");
        assert_eq!(number_readable(78_155), "78,155");
        assert_eq!(number_readable(1_000_000), "1,000,000");
    }
}
