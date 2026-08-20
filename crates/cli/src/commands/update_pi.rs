use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use kendex_core::env::Env;
use kendex_core::harness::HarnessAdapter;
use kendex_core::harness::pi::Pi;
use kendex_core::manifest::ManifestFile;
use kendex_core::model::Scope;
use kendex_core::process::Hardened;
use kendex_core::{manifest, pi_ext, settings, source};

use super::{CliResult, out, resolve_scopes, say};
use crate::scope::ScopeFilter;

/// What update-pi found for one declared or installed package.
enum Status {
    Current,
    /// The declared source ships different bytes than the installed copy.
    Stale {
        source_dir: PathBuf,
    },
    /// Declared but not installed in this scope yet.
    Missing {
        source_dir: PathBuf,
    },
    /// Pi loads both scopes together, so the same (or legacy-renamed)
    /// package at the other scope would register twice and crash Pi.
    Blocked {
        reason: String,
    },
    /// Installed under `packages/`, but no declared source ships it.
    Unsourced,
    /// An `npm:` entry in Pi's settings: Pi resolves these itself, so kendex
    /// reports the version and leaves the package alone.
    Npm {
        latest: Option<String>,
    },
}

struct Row {
    name: String,
    version: Option<String>,
    status: Status,
}

struct ScopePlan {
    label: String,
    root: PathBuf,
    rows: Vec<Row>,
    notes: Vec<String>,
}

/// Compare every installed Pi package against the source it came from and
/// reinstall the ones that fell behind.
pub fn run(env: &Env, filter: ScopeFilter, check: bool) -> CliResult {
    let settings = settings::load(env)?;
    let global_root = settings
        .harness_roots
        .get(Pi.id().name())
        .cloned()
        .unwrap_or_else(|| Pi.default_global_root(env));
    let mut plans = Vec::new();
    for scope in resolve_scopes(env, filter)? {
        let root = match &scope {
            Scope::Global => global_root.clone(),
            Scope::Project { root } => root.join(".pi"),
        };
        // Pi loads the other scope's packages alongside this one's, so an
        // install here must be checked against every root Pi could pair
        // this scope with.
        let other_roots: Vec<PathBuf> = match &scope {
            Scope::Global => settings.projects.iter().map(|p| p.join(".pi")).collect(),
            Scope::Project { .. } => vec![global_root.clone()],
        };
        if root.is_dir() || scope_declares_extensions(env, &scope) {
            plans.push(plan_scope(env, &scope, root, &other_roots)?);
        }
    }

    if plans.is_empty() {
        say("no pi scope on this machine");
        return Ok(());
    }
    for plan in &plans {
        print_plan(plan);
    }

    if check {
        let pending = plans.iter().flat_map(|p| &p.rows).filter(updatable).count();
        if pending > 0 {
            say(&format!(
                "{pending} package(s) can be updated — run without --check to apply"
            ));
        }
        return Ok(());
    }
    update(env, &plans)
}

fn updatable(row: &&Row) -> bool {
    matches!(row.status, Status::Stale { .. } | Status::Missing { .. })
}

fn scope_declares_extensions(env: &Env, scope: &Scope) -> bool {
    matches!(
        manifest::load(&manifest::manifest_path(env, scope)),
        Ok(ManifestFile::Current(manifest)) if !manifest.pi_extensions.is_empty()
    )
}

fn plan_scope(
    env: &Env,
    scope: &Scope,
    root: PathBuf,
    other_roots: &[PathBuf],
) -> Result<ScopePlan, Box<dyn std::error::Error>> {
    let mut notes = Vec::new();
    let sources = declared_sources(env, scope, &mut notes);
    let mut rows = Vec::new();

    let guard = |name: &str, status: Status| match pi_ext::duplicate_elsewhere(name, other_roots) {
        Some((conflict, at)) => Status::Blocked {
            reason: format!(
                "blocked: {conflict} is installed at {} and would register twice — remove it there first",
                at.display()
            ),
        },
        None => status,
    };

    let installed_names = pi_ext::list_installed(&root)?;
    for name in &installed_names {
        let status = match sources.get(name) {
            None => Status::Unsourced,
            // One unreadable package (a symlink in its source, a blown
            // budget) must not empty the whole listing — it gets its own
            // note and the healthy rows still print.
            Some(source_dir) => match (
                pi_ext::installed_hash(&root, name),
                pi_ext::package_hash(source_dir),
            ) {
                (Ok(installed), Ok(source)) if installed.is_some() && installed == source => {
                    Status::Current
                }
                (Ok(_), Ok(_)) => guard(
                    name,
                    Status::Stale {
                        source_dir: source_dir.clone(),
                    },
                ),
                (Err(error), _) | (_, Err(error)) => {
                    notes.push(format!("{name}: unreadable — {error}"));
                    continue;
                }
            },
        };
        let version = installed_version(&root, name);
        rows.push(Row {
            name: name.clone(),
            version,
            status,
        });
    }

    for (name, source_dir) in &sources {
        if installed_names.contains(name) {
            continue;
        }
        rows.push(Row {
            name: name.clone(),
            version: None,
            status: guard(
                name,
                Status::Missing {
                    source_dir: source_dir.clone(),
                },
            ),
        });
    }

    for name in pi_ext::list_npm_entries(&root)? {
        let version = installed_version(&root, &name);
        let latest = npm_latest(&name);
        rows.push(Row {
            name,
            version,
            status: Status::Npm { latest },
        });
    }

    Ok(ScopePlan {
        label: scope.label(),
        root,
        rows,
        notes,
    })
}

/// Where each declared pi-extension's bytes live right now. A source that
/// cannot be read is a note, not a failure — the rest of the scope still
/// updates.
fn declared_sources(
    env: &Env,
    scope: &Scope,
    notes: &mut Vec<String>,
) -> BTreeMap<String, PathBuf> {
    let mut found = BTreeMap::new();
    let path = manifest::manifest_path(env, scope);
    let manifest = match manifest::load(&path) {
        Ok(ManifestFile::Current(manifest)) => manifest,
        Ok(_) => return found,
        Err(error) => {
            notes.push(error.to_string());
            return found;
        }
    };
    for (name, decl) in &manifest.pi_extensions {
        match source::require_ready(env, scope, &decl.source, &manifest) {
            Ok(ready) => {
                let base = ready.root.join("pi-extensions");
                let dir = base.join(name);
                if dir.join("package.json").is_file() {
                    found.insert(name.clone(), dir);
                } else if let Some(dir) = pi_ext::find_by_package_name(&base, name) {
                    found.insert(name.clone(), dir);
                } else {
                    notes.push(format!(
                        "{name}: source '{}' no longer ships pi-extensions/{name}",
                        decl.source
                    ));
                }
            }
            Err(error) => notes.push(format!("{name}: {error}")),
        }
    }
    found
}

fn installed_version(root: &Path, name: &str) -> Option<String> {
    pi_ext::read(&pi_ext::packages_dir(root).join(name))
        .ok()
        .and_then(|package| package.version)
}

/// Best effort: no npm, no network, or an unpublished package all read as an
/// unknown latest version rather than a failed run.
fn npm_latest(name: &str) -> Option<String> {
    let output = Hardened::npm(&["view", name, "version", "--json"], None)
        .run()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8(output.stdout).ok()?;
    serde_json::from_str::<serde_json::Value>(text.trim())
        .ok()?
        .as_str()
        .map(str::to_owned)
}

fn semver(version: &str) -> Vec<u64> {
    let mut parts: Vec<u64> = version
        .trim()
        .trim_start_matches('v')
        .split(['-', '+'])
        .next()
        .unwrap_or_default()
        .split('.')
        .map(|part| part.parse().unwrap_or_default())
        .collect();
    parts.resize(3, 0);
    parts
}

fn print_plan(plan: &ScopePlan) {
    say(&format!("{} ({})", plan.label, plan.root.display()));
    if plan.rows.is_empty() {
        say("  no pi packages installed");
    }
    for row in &plan.rows {
        out(&format!(
            "  {:<34} {:<22} {}",
            row.name,
            versions(row),
            describe(row)
        ));
    }
    for note in &plan.notes {
        say(&format!("  ! {note}"));
    }
}

fn versions(row: &Row) -> String {
    let installed = row.version.as_deref().unwrap_or("-");
    match &row.status {
        Status::Npm {
            latest: Some(latest),
        } if latest != installed => {
            format!("{installed} -> {latest}")
        }
        _ => installed.to_owned(),
    }
}

fn describe(row: &Row) -> String {
    match &row.status {
        Status::Current => "up to date".to_owned(),
        Status::Stale { .. } => "stale (source changed)".to_owned(),
        Status::Missing { .. } => "not installed yet".to_owned(),
        Status::Blocked { reason } => reason.clone(),
        Status::Unsourced => "no declared source".to_owned(),
        Status::Npm { latest } => match latest {
            None => "npm, latest unknown".to_owned(),
            Some(latest) => match &row.version {
                Some(installed) if semver(latest) > semver(installed) => {
                    "npm, update available".to_owned()
                }
                Some(_) => "npm, up to date".to_owned(),
                None => "npm, managed by pi".to_owned(),
            },
        },
    }
}

fn update(env: &Env, plans: &[ScopePlan]) -> CliResult {
    let mut updated = 0usize;
    let mut failures: Vec<String> = Vec::new();
    for plan in plans {
        for row in &plan.rows {
            let (source_dir, verb) = match &row.status {
                Status::Stale { source_dir } => (source_dir, "updated"),
                Status::Missing { source_dir } => (source_dir, "installed"),
                _ => continue,
            };
            match pi_ext::install(env, &plan.root, source_dir) {
                Ok(outcome) => {
                    updated += 1;
                    out(&format!(
                        "  {verb} {} -> {}",
                        row.name,
                        outcome.version.as_deref().unwrap_or("?")
                    ));
                    for bin in &outcome.unbuilt_bins {
                        say(&format!(
                            "  ! {}: bin '{bin}' is not built, so no command was linked",
                            row.name
                        ));
                    }
                }
                Err(error) => {
                    say(&format!("  failed {}: {error}", row.name));
                    failures.push(format!("{} ({})", row.name, plan.label));
                }
            }
        }
    }
    if failures.is_empty() {
        say(&match updated {
            0 => "all pi packages up to date".to_owned(),
            count => format!("updated {count} package(s)"),
        });
        return Ok(());
    }
    Err(format!("update failed for: {}", failures.join(", ")).into())
}
