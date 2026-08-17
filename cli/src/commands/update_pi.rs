use anyhow::{Context, Result};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::pi_extension::{
    self, PiExtension, SourceIndex, install_pi_extension, is_pi_extension_installed,
    list_installed_vstack_packages, list_npm_packages, read_source_index,
};

/// What a package whose source cache is being rewritten is told. It is not an
/// update to skip and not a broken package: re-running answers it.
const BUSY_SOURCE_NOTE: &str =
    "another vstack process is refreshing this source's cache — re-run once it finishes";

/// What kind of source a package was installed from.
#[derive(Debug, Clone, PartialEq, Eq)]
enum SourceKind {
    /// Copied from a vstack repo's `pi-extensions/<name>/` dir.
    Vstack { repo: PathBuf },
    /// Installed from npm via `npm:<pkg>` in pi `settings.json`.
    Npm,
    /// Listed as installed but no source info recoverable.
    Unknown,
}

/// Status of a planned package after version comparison.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Status {
    UpToDate,
    Outdated,
    /// Listed as installed (settings.json or packages dir) but version info or
    /// source repo is unreachable, so we can't decide. Skipped during update.
    Unknown,
    /// In source index but no longer present in `<scope>/packages/`. We'll
    /// drop the index entry on update to keep tracking clean.
    StaleIndex,
    /// `npm:<pkg>` reachable in settings.json but `npm view` failed (offline,
    /// missing pkg, etc.). Skipped.
    NpmLookupFailed,
}

#[derive(Debug, Clone)]
struct PlanItem {
    name: String,
    global: bool,
    source: SourceKind,
    installed_version: Option<String>,
    latest_version: Option<String>,
    status: Status,
    note: Option<String>,
}

/// Allowed values for the `--scope` flag. Kept as a thin wrapper over the
/// shared `crate::scope::ScopeFilter` so update-pi behaves like the rest of
/// the CLI; returns the boolean `global` flags it covers.
fn parse_scope_filter(scope: Option<&str>) -> Result<Vec<bool>> {
    let filter = crate::scope::ScopeFilter::resolve(scope, false, crate::scope::ScopeFilter::All)?;
    Ok(filter.globals().to_vec())
}

/// Read a package.json `version` field if present.
fn read_installed_version(package_dir: &Path) -> Option<String> {
    let manifest = package_dir.join("package.json");
    let raw = std::fs::read_to_string(&manifest).ok()?;
    let parsed: serde_json::Value = serde_json::from_str(&raw).ok()?;
    parsed
        .get("version")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
}

/// Read the `version` field from a source-side `package.json`.
/// Tries `source_path` first (most accurate — covers cases where dir name
/// differs from package name), then falls back to `<repo>/pi-extensions/<name>`.
fn read_source_version(
    repo: &Path,
    source_path: Option<&Path>,
    name: &str,
) -> (Option<String>, Option<PathBuf>) {
    let candidates: Vec<PathBuf> = source_path
        .map(|p| p.to_path_buf())
        .into_iter()
        .chain(std::iter::once(repo.join("pi-extensions").join(name)))
        .collect();
    for dir in candidates {
        let manifest = dir.join("package.json");
        let Ok(raw) = std::fs::read_to_string(&manifest) else {
            continue;
        };
        let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&raw) else {
            continue;
        };
        if let Some(v) = parsed.get("version").and_then(|v| v.as_str()) {
            return (Some(v.to_string()), Some(dir));
        }
    }
    (None, None)
}

/// Strip leading `v` and any `-suffix`/`+meta`, then split on `.` into u64s.
/// Returns None if any segment fails to parse.
fn parse_semver(v: &str) -> Option<Vec<u64>> {
    let cleaned = v.trim().trim_start_matches('v');
    let head = cleaned.split(['-', '+']).next()?;
    let parts: Option<Vec<u64>> = head.split('.').map(|s| s.parse::<u64>().ok()).collect();
    let mut parts = parts?;
    while parts.len() < 3 {
        parts.push(0);
    }
    Some(parts)
}

/// True if `latest` > `current`. Either side missing or unparseable returns false
/// (so the caller treats it as "not outdated" rather than blowing up the run).
fn is_newer(latest: Option<&str>, current: Option<&str>) -> bool {
    let (Some(l), Some(c)) = (latest, current) else {
        return false;
    };
    let (Some(la), Some(cu)) = (parse_semver(l), parse_semver(c)) else {
        return false;
    };
    let len = la.len().max(cu.len());
    for i in 0..len {
        let a = la.get(i).copied().unwrap_or(0);
        let b = cu.get(i).copied().unwrap_or(0);
        if a > b {
            return true;
        }
        if a < b {
            return false;
        }
    }
    false
}

/// Best-effort `npm view <name> version`. Returns None on any failure (network,
/// missing npm, package not found). Caller surfaces this as `NpmLookupFailed`.
fn npm_latest_version(name: &str) -> Option<String> {
    let out = std::process::Command::new("npm")
        .args(["view", name, "version", "--json"])
        .stdin(std::process::Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let stdout = String::from_utf8(out.stdout).ok()?;
    let trimmed = stdout.trim();
    if trimmed.is_empty() {
        return None;
    }
    // `npm view foo version --json` returns a JSON-quoted string for a single
    // version. Strip the quotes; if `--json` failed for some reason and we got
    // raw text, fall back to that.
    let unquoted: serde_json::Value = serde_json::from_str(trimmed).ok()?;
    unquoted.as_str().map(|s| s.to_string())
}

/// Build the plan for one scope by walking the source index, the installed
/// packages dir, and the settings.json `npm:` entries. Each candidate ends up
/// with a single PlanItem.
fn plan_for_scope(global: bool) -> Result<Vec<PlanItem>> {
    let scope_label = if global { "global" } else { "project" };
    let index = read_source_index(global).with_context(|| {
        format!("reading {scope_label} scope source index — fix or delete the file")
    })?;
    let installed = list_installed_vstack_packages(global);
    let npm_entries = list_npm_packages(global)?;

    let installed_set: std::collections::BTreeSet<String> = installed.iter().cloned().collect();
    let mut planned: BTreeMap<String, PlanItem> = BTreeMap::new();

    // 1) Anything in the source index — the canonical record of what vstack installed.
    for (name, entry) in &index {
        let installed_dir = crate::config::pi_packages_dir(global).join(name);
        let installed_present = installed_set.contains(name);
        let installed_version = installed_present
            .then(|| read_installed_version(&installed_dir))
            .flatten();

        if !installed_present {
            planned.insert(
                name.clone(),
                PlanItem {
                    name: name.clone(),
                    global,
                    source: SourceKind::Unknown,
                    installed_version: None,
                    latest_version: None,
                    status: Status::StaleIndex,
                    note: Some("source index entry but no installed package".to_string()),
                },
            );
            continue;
        }

        let Some(repo_str) = entry.source_repo.clone() else {
            planned.insert(
                name.clone(),
                PlanItem {
                    name: name.clone(),
                    global,
                    source: SourceKind::Unknown,
                    installed_version,
                    latest_version: None,
                    status: Status::Unknown,
                    note: Some("source index entry missing sourceRepo".to_string()),
                },
            );
            continue;
        };
        let repo = PathBuf::from(&repo_str);

        if !repo.exists() {
            planned.insert(
                name.clone(),
                PlanItem {
                    name: name.clone(),
                    global,
                    source: SourceKind::Vstack { repo: repo.clone() },
                    installed_version,
                    latest_version: None,
                    status: Status::Unknown,
                    note: Some(format!("source repo not found: {}", repo.display())),
                },
            );
            continue;
        }
        // A cache another vstack process is fetching and resetting answers the
        // version question with whatever the reset has written so far — an
        // older revision reads as an update to install, and a missing
        // `package.json` reads as a package with no version at all. Neither is
        // this package's state, so the plan says so instead of guessing.
        if crate::config::remote_cache_fetch_in_flight(&repo) {
            planned.insert(
                name.clone(),
                PlanItem {
                    name: name.clone(),
                    global,
                    source: SourceKind::Vstack { repo: repo.clone() },
                    installed_version,
                    latest_version: None,
                    status: Status::Unknown,
                    note: Some(BUSY_SOURCE_NOTE.to_string()),
                },
            );
            continue;
        }

        let source_path = entry.source_path.as_ref().map(PathBuf::from);
        let (latest, _resolved_dir) = read_source_version(&repo, source_path.as_deref(), name);
        let status = if is_newer(latest.as_deref(), installed_version.as_deref()) {
            Status::Outdated
        } else if latest.is_some() {
            Status::UpToDate
        } else {
            Status::Unknown
        };
        let note = if matches!(status, Status::Unknown) {
            Some(format!(
                "no readable package.json under {} or {}",
                source_path
                    .as_deref()
                    .map(|p| p.display().to_string())
                    .unwrap_or_else(|| "(no sourcePath)".to_string()),
                repo.join("pi-extensions").join(name).display(),
            ))
        } else {
            None
        };
        planned.insert(
            name.clone(),
            PlanItem {
                name: name.clone(),
                global,
                source: SourceKind::Vstack { repo },
                installed_version,
                latest_version: latest,
                status,
                note,
            },
        );
    }

    // 2) Installed packages not represented in the index — vstack didn't install
    //    them or the index was wiped. Surface as Unknown so the user can decide.
    for name in &installed {
        if planned.contains_key(name) {
            continue;
        }
        let installed_dir = crate::config::pi_packages_dir(global).join(name);
        let installed_version = read_installed_version(&installed_dir);
        planned.insert(
            name.clone(),
            PlanItem {
                name: name.clone(),
                global,
                source: SourceKind::Unknown,
                installed_version,
                latest_version: None,
                status: Status::Unknown,
                note: Some(
                    "no source index entry; reinstall via `vstack add` to track".to_string(),
                ),
            },
        );
    }

    // 3) npm: packages from settings.json. These never appear in the source
    //    index. Settings.json entry is authoritative — if a name appears as both
    //    npm and vstack-source, the npm entry wins (rare; would mean dual install).
    for npm_name in &npm_entries {
        let installed_version = npm_installed_version(npm_name);
        let latest_version = npm_latest_version(npm_name);
        let status = match (&latest_version, &installed_version) {
            (None, _) => Status::NpmLookupFailed,
            (Some(latest), current) => {
                if is_newer(Some(latest.as_str()), current.as_deref()) {
                    Status::Outdated
                } else {
                    Status::UpToDate
                }
            }
        };
        // Use the npm name as the plan key — never collides with vstack-copied
        // packages because they live in `<scope>/packages/<bare-name>` while npm
        // packages aren't copied locally.
        planned.insert(
            format!("npm:{npm_name}"),
            PlanItem {
                name: npm_name.clone(),
                global,
                source: SourceKind::Npm,
                installed_version,
                latest_version,
                status,
                note: None,
            },
        );
    }

    Ok(planned.into_values().collect())
}

/// Resolve installed version of an npm package by walking `npm root -g` /
/// project node_modules. Falls back to None.
fn npm_installed_version(name: &str) -> Option<String> {
    let candidates = npm_root_candidates();
    for root in candidates {
        let manifest = root.join(name).join("package.json");
        if let Ok(raw) = std::fs::read_to_string(&manifest)
            && let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&raw)
            && let Some(version) = parsed.get("version").and_then(|v| v.as_str())
        {
            return Some(version.to_string());
        }
    }
    None
}

fn npm_root_candidates() -> Vec<PathBuf> {
    let mut roots = Vec::new();
    if let Ok(out) = std::process::Command::new("npm")
        .args(["root", "-g"])
        .output()
        && out.status.success()
        && let Ok(s) = String::from_utf8(out.stdout)
    {
        let trimmed = s.trim();
        if !trimmed.is_empty() {
            roots.push(PathBuf::from(trimmed));
        }
    }
    if let Some(home) = dirs::home_dir() {
        roots.push(home.join(".local/lib/node_modules"));
        roots.push(home.join("node_modules"));
    }
    roots
}

fn print_plan(plan: &[PlanItem]) {
    if plan.is_empty() {
        println!("No pi extensions found in any scope.");
        return;
    }
    let mut by_scope: BTreeMap<&str, Vec<&PlanItem>> = BTreeMap::new();
    for item in plan {
        let key = if item.global { "global" } else { "project" };
        by_scope.entry(key).or_default().push(item);
    }
    for (scope, items) in &by_scope {
        println!("\n{scope} scope:");
        for item in items {
            let installed = item.installed_version.as_deref().unwrap_or("?");
            let latest = item.latest_version.as_deref().unwrap_or("?");
            let source = match &item.source {
                SourceKind::Vstack { repo } => format!("vstack: {}", repo.display()),
                SourceKind::Npm => "npm".to_string(),
                SourceKind::Unknown => "unknown".to_string(),
            };
            let status_text = match item.status {
                Status::UpToDate => "up to date",
                Status::Outdated => "UPDATE",
                Status::Unknown => "?",
                Status::StaleIndex => "stale index entry",
                Status::NpmLookupFailed => "npm lookup failed",
            };
            let version_part = match item.status {
                Status::Outdated => format!("{installed} -> {latest}"),
                Status::UpToDate => installed.to_string(),
                _ => installed.to_string(),
            };
            let note = item
                .note
                .as_ref()
                .map(|n| format!("  ({n})"))
                .unwrap_or_default();
            println!(
                "  {:<32} {:<22} {:<8} ({source}){note}",
                item.name, version_part, status_text
            );
        }
    }
}

fn execute(plan: &[PlanItem]) -> Result<()> {
    // Group vstack-source updates by (scope, repo) so we discover each repo
    // exactly once. npm updates run per-package since `npm install -g` doesn't
    // benefit from batching.
    let mut vstack_groups: BTreeMap<(bool, PathBuf), Vec<String>> = BTreeMap::new();
    let mut npm_updates: Vec<(bool, String)> = Vec::new();
    let mut stale_clean: Vec<(bool, String)> = Vec::new();

    for item in plan {
        match (&item.status, &item.source) {
            (Status::Outdated, SourceKind::Vstack { repo }) => {
                vstack_groups
                    .entry((item.global, repo.clone()))
                    .or_default()
                    .push(item.name.clone());
            }
            (Status::Outdated, SourceKind::Npm) => {
                npm_updates.push((item.global, item.name.clone()));
            }
            (Status::StaleIndex, _) => {
                stale_clean.push((item.global, item.name.clone()));
            }
            _ => {}
        }
    }

    let total = vstack_groups.values().map(|v| v.len()).sum::<usize>() + npm_updates.len();
    if total == 0 && stale_clean.is_empty() {
        println!("\nAll pi extensions up to date.");
        return Ok(());
    }

    let mut succeeded = 0usize;
    let mut failed: Vec<String> = Vec::new();

    if total > 0 {
        println!("\nUpdating {total} package(s)...");
    }

    for ((global, repo), names) in &vstack_groups {
        let scope_label = if *global { "global" } else { "project" };
        // Re-asked here because this is the read that MATTERS: the plan was
        // computed a moment ago, and what follows discovers this tree and
        // copies packages out of it into a live Pi install.
        if crate::config::remote_cache_fetch_in_flight(repo) {
            eprintln!("  ✗ {} ({scope_label}): {BUSY_SOURCE_NOTE}", repo.display());
            for name in names {
                failed.push(format!("{name} ({scope_label})"));
            }
            continue;
        }
        let extensions = match crate::catalog::discover_pi_extensions(repo) {
            Ok(list) => list,
            Err(e) => {
                eprintln!("  ✗ failed to scan {} ({scope_label}): {e}", repo.display());
                for name in names {
                    failed.push(format!("{name} ({scope_label})"));
                }
                continue;
            }
        };
        for name in names {
            let Some(ext) = extensions.iter().find(|e| &e.name == name) else {
                eprintln!(
                    "  ✗ {name} ({scope_label}): not found in source catalog at {}",
                    repo.display()
                );
                failed.push(format!("{name} ({scope_label})"));
                continue;
            };
            match install_one_vstack(ext, *global) {
                Ok(version) => {
                    println!("  ✓ {name} ({scope_label}) → {version}");
                    succeeded += 1;
                }
                Err(e) => {
                    eprintln!("  ✗ {name} ({scope_label}): {e}");
                    failed.push(format!("{name} ({scope_label})"));
                }
            }
        }
    }

    for (global, name) in &npm_updates {
        let scope_label = if *global { "global" } else { "project" };
        match install_one_npm(name) {
            Ok(()) => {
                println!(
                    "  ✓ {name} ({scope_label}) [npm install -g {}]",
                    crate::display::command_arg(&format!("{name}@latest"))
                );
                succeeded += 1;
            }
            Err(e) => {
                eprintln!("  ✗ {name} ({scope_label}): {e}");
                failed.push(format!("{name} ({scope_label})"));
            }
        }
    }

    for (global, name) in &stale_clean {
        if let Err(e) = drop_stale_index_entry(name, *global) {
            eprintln!("  ! could not drop stale index entry for {name}: {e}");
        } else {
            let scope_label = if *global { "global" } else { "project" };
            println!("  · cleaned stale source index entry: {name} ({scope_label})");
        }
    }

    println!(
        "\nDone. {succeeded} updated, {} failed, {} stale entries cleaned.",
        failed.len(),
        stale_clean.len()
    );
    if !failed.is_empty() {
        anyhow::bail!("update failed for: {}", failed.join(", "));
    }
    Ok(())
}

fn install_one_vstack(ext: &PiExtension, global: bool) -> Result<String> {
    if !is_pi_extension_installed(&ext.name, global) {
        anyhow::bail!("not currently installed at this scope; aborting to avoid surprise install");
    }
    install_pi_extension(ext, global)?;
    Ok(ext.version.clone().unwrap_or_else(|| "?".to_string()))
}

fn install_one_npm(name: &str) -> Result<()> {
    let target = format!("{name}@latest");
    let out = std::process::Command::new("npm")
        .args(["install", "-g", &target])
        .stdin(std::process::Stdio::null())
        .output()
        .with_context(|| "running npm — is it on PATH?".to_string())?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        anyhow::bail!("npm install failed: {}", stderr.trim());
    }
    Ok(())
}

fn drop_stale_index_entry(name: &str, global: bool) -> Result<()> {
    let mut index: SourceIndex = pi_extension::read_source_index(global)?;
    if index.remove(name).is_some() {
        pi_extension::write_source_index(global, &index)?;
    }
    Ok(())
}

pub fn run(check: bool, scope: Option<String>) -> Result<()> {
    let scopes = parse_scope_filter(scope.as_deref())?;
    let mut plan: Vec<PlanItem> = Vec::new();
    for &global in &scopes {
        plan.extend(plan_for_scope(global)?);
    }

    print_plan(&plan);

    if check {
        let outdated = plan
            .iter()
            .filter(|p| matches!(p.status, Status::Outdated))
            .count();
        if outdated > 0 {
            println!(
                "\n{outdated} package(s) have updates available. Run without --check to apply."
            );
        }
        return Ok(());
    }

    execute(&plan)?;
    Ok(())
}

#[cfg(test)]
mod tests;
