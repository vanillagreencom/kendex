use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use kendex_core::env::Env;
use kendex_core::harness::HarnessAdapter;
use kendex_core::harness::pi::Pi;
use kendex_core::manifest::ManifestFile;
use kendex_core::model::Scope;
use kendex_core::process::Hardened;
use kendex_core::{manifest, pi_ext, settings};

use super::{CliResult, out, resolve_scopes, say};
use crate::scope::ScopeFilter;

/// What update-pi found for one declared or installed package.
enum Status {
    Current,
    /// The package files or completed record differ from the declaration.
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
    scope: Scope,
    label: String,
    root: PathBuf,
    rows: Vec<Row>,
    notes: Vec<String>,
}

/// Compare every installed Pi package against the source it came from and
/// reinstall the ones that fell behind.
pub fn run(env: &Env, filter: ScopeFilter, check: bool) -> CliResult {
    let settings = settings::load(env)?;
    let scopes = resolve_scopes(env, filter)?;
    let mut guards = Vec::new();
    if !check {
        for scope in &scopes {
            guards.push(hold_scope(env, scope)?);
        }
    }
    let mut plans = Vec::new();
    for scope in scopes {
        let (root, other_roots) = roots(env, &settings, &scope);
        if root.is_dir() || scope_declares_extensions(env, &scope) {
            plans.push(plan_scope(env, &scope, root, &other_roots)?);
        }
    }

    if plans.is_empty() {
        say("no place on this computer installs for Pi");
        return Ok(());
    }
    for plan in &plans {
        print_plan(plan);
    }

    if check {
        let pending = plans.iter().flat_map(|p| &p.rows).filter(updatable).count();
        if pending > 0 {
            say(&format!(
                "{pending} package(s) can be updated — run without --check to update them"
            ));
        }
        return Ok(());
    }
    update(env, &plans)
}

fn updatable(row: &&Row) -> bool {
    matches!(row.status, Status::Stale { .. } | Status::Missing { .. })
}

/// The declared packages `settle_scope` would install in this scope, read
/// the way it reads them and writing nothing: what a verb shows before it
/// asks for the yes that lets the settle write, and the names it then
/// hands the settle.
pub fn pending_settle(env: &Env, scope: &Scope) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let settings = settings::load(env)?;
    let (root, other_roots) = roots(env, &settings, scope);
    Ok(settleable(env, scope, &root, &other_roots)?
        .into_iter()
        .map(|(name, _)| name)
        .collect())
}

/// Settle the named declared packages for a verb about to plan the scope:
/// install them and record what landed, the way this verb does for the
/// scopes it is run on. `refresh` calls it once the person has said yes to
/// the names `pending_settle` read, so a clone carrying no install record,
/// or a scope whose unedited copy fell behind its source, refreshes in one
/// run instead of failing until `update-pi` is run by hand; a name no
/// longer settleable under the lock is left as it stands.
///
/// Says what it installed and returns how many: the plan the caller
/// derives next reports every package still unsettled as drift, and that
/// row is the run's failure. Only the scope lock and the install record
/// can stop the scope. The lock is held for the install alone; the
/// caller's own write takes it again.
pub fn settle_scope(
    env: &Env,
    scope: &Scope,
    names: &[String],
) -> Result<usize, Box<dyn std::error::Error>> {
    let settings = settings::load(env)?;
    let (root, other_roots) = roots(env, &settings, scope);
    let _guard = hold_scope(env, scope)?;
    let rows = settleable(env, scope, &root, &other_roots)?
        .into_iter()
        .filter(|(name, _)| names.contains(name))
        .map(|(name, status)| Row {
            version: installed_version(&root, &name),
            name,
            status,
        })
        .collect();
    let plan = ScopePlan {
        scope: scope.clone(),
        label: scope.label(),
        root,
        rows,
        notes: Vec::new(),
    };
    Ok(install_rows(env, &plan)?.count)
}

/// What a settle may install, decided once and here: a declared package
/// whose source resolves, which no other root Pi loads already registers
/// under this or an earlier name, whose own root holds no copy under an
/// earlier name either, and whose install runs no process; and either the
/// install record does not hold it at all, which is what a fresh clone
/// carries, and its installed copy is absent or byte-equal to that source
/// (`Missing`), or the record holds it from the same origin, its installed
/// copy is still the bytes that record completed, and the source moved
/// away from them (`Stale`). `pi_ext::install` runs `npm install` for a
/// package declaring dependencies, and with it that package's own
/// lifecycle scripts; a refresh settles on the strength of a fetch it just
/// made, and running a script that arrived with that fetch is running a
/// checkout's script on the checkout's own say-so, the rule
/// `commands::repo_effects` states. A recorded package whose installed
/// files no longer match its completed record (edited, or an interrupted
/// install) is the person's to update; so is an unrecorded copy whose
/// bytes differ from the source, which a lockless scope refuses to record
/// rather than replaces; and one whose metadata will not read, resolve or
/// compare is left as it stands: no read of one package stops the scope,
/// only the record's.
fn settleable(
    env: &Env,
    scope: &Scope,
    root: &Path,
    other_roots: &[PathBuf],
) -> Result<Vec<(String, Status)>, Box<dyn std::error::Error>> {
    let Ok(ManifestFile::Current(manifest)) = manifest::load(&manifest::manifest_path(env, scope))
    else {
        return Ok(Vec::new());
    };
    if manifest.pi_extensions.is_empty() {
        return Ok(Vec::new());
    }
    let lock = kendex_core::lock::load(&kendex_core::lock::lock_path(env, scope))?;
    let mut found = Vec::new();
    for (name, decl) in &manifest.pi_extensions {
        let key = kendex_core::lock::entry_key(
            kendex_core::model::ItemKind::PiExtension,
            name,
            kendex_core::model::HarnessId::Pi,
        );
        let own = [root.to_path_buf()];
        if pi_ext::duplicate_elsewhere(name, other_roots).is_some()
            || pi_ext::legacy_names(name)
                .iter()
                .any(|legacy| pi_ext::duplicate_elsewhere(legacy, &own).is_some())
        {
            continue;
        }
        let Ok(package) = pi_ext::resolve_declared(env, scope, &manifest, name, decl) else {
            continue;
        };
        let installed = pi_ext::declared_state(
            root,
            name,
            &package,
            None,
            pi_ext::RecordBasis::MatchedBytes,
        );
        let source_dir = package.source_dir.clone();
        let status = match (lock.entries.get(&key), installed) {
            (None, Ok(pi_ext::PackageState::Missing | pi_ext::PackageState::Current { .. })) => {
                Status::Missing { source_dir }
            }
            (Some(entry), Ok(pi_ext::PackageState::Different))
                if pi_ext::check_origin(name, &package, Some(entry)).is_ok()
                    && matches!(
                        pi_ext::installed_state(root, name, entry.rendered_hash.as_deref()),
                        Ok(pi_ext::PackageState::Current { .. })
                    ) =>
            {
                Status::Stale { source_dir }
            }
            (None, Ok(pi_ext::PackageState::Different)) | (Some(_), _) | (_, Err(_)) => continue,
        };
        if pi_ext::declares_runtime_deps(&package.source_dir).is_ok_and(|deps| !deps) {
            found.push((name.clone(), status));
        }
    }
    Ok(found)
}

/// The scope lock a Pi install runs under, taken after any interrupted
/// apply is rolled back and only once the install record reads.
fn hold_scope(
    env: &Env,
    scope: &Scope,
) -> Result<kendex_core::apply::ScopeGuard, Box<dyn std::error::Error>> {
    let guard = kendex_core::apply::lock_scope(env, scope)?;
    kendex_core::apply::recover(env, scope)?;
    kendex_core::lock::load(&kendex_core::lock::lock_path(env, scope))?;
    Ok(guard)
}

/// Where a scope's packages install, and the roots Pi loads beside it: Pi
/// loads the other scope's packages alongside this one's, so an install
/// here must be checked against every root Pi could pair this scope with,
/// the project the command runs in included, registered or not.
fn roots(env: &Env, settings: &settings::AppSettings, scope: &Scope) -> (PathBuf, Vec<PathBuf>) {
    let global_root = settings
        .harness_roots
        .get(Pi.id().name())
        .cloned()
        .unwrap_or_else(|| Pi.default_global_root(env));
    let here = super::current_project(env);
    match scope {
        Scope::Global => (
            global_root,
            settings
                .projects
                .iter()
                .chain(here.as_ref())
                .map(|p| p.join(".pi"))
                .collect(),
        ),
        Scope::Project { root } => (root.join(".pi"), vec![global_root]),
    }
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
    let lock = kendex_core::lock::load(&kendex_core::lock::lock_path(env, scope))?;
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

    for (name, package) in &sources {
        let key = kendex_core::lock::entry_key(
            kendex_core::model::ItemKind::PiExtension,
            name,
            kendex_core::model::HarnessId::Pi,
        );
        let existing = lock.entries.get(&key);
        pi_ext::check_origin(name, package, existing)?;
        let status = match pi_ext::declared_state(
            &root,
            name,
            package,
            existing,
            pi_ext::RecordBasis::Recorded,
        ) {
            Ok(pi_ext::PackageState::Current { .. }) => Status::Current,
            Ok(pi_ext::PackageState::Different) => guard(
                name,
                Status::Stale {
                    source_dir: package.source_dir.clone(),
                },
            ),
            Ok(pi_ext::PackageState::Missing) => guard(
                name,
                Status::Missing {
                    source_dir: package.source_dir.clone(),
                },
            ),
            Err(error) => {
                notes.push(format!("{name}: unreadable — {error}"));
                continue;
            }
        };
        rows.push(Row {
            name: name.clone(),
            version: installed_version(&root, name),
            status,
        });
    }
    for name in pi_ext::list_installed(&root)? {
        if !sources.contains_key(&name) {
            rows.push(Row {
                version: installed_version(&root, &name),
                name,
                status: Status::Unsourced,
            });
        }
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
        scope: scope.clone(),
        label: scope.label(),
        root,
        rows,
        notes,
    })
}

/// Resolve each declared Pi extension. An unreadable source becomes a note
/// so the rest of the scope still updates.
fn declared_sources(
    env: &Env,
    scope: &Scope,
    notes: &mut Vec<String>,
) -> BTreeMap<String, pi_ext::DeclaredPackage> {
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
        match pi_ext::resolve_declared(env, scope, &manifest, name, decl) {
            Ok(package) => {
                found.insert(name.clone(), package);
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
        say(&format!("  ! {}", note));
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
        Status::Stale { .. } => "stale (package or install record differs)".to_owned(),
        Status::Missing { .. } => "not installed yet".to_owned(),
        Status::Blocked { reason } => reason.clone(),
        Status::Unsourced => "not listed in this place".to_owned(),
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
        let installed = install_rows(env, plan)?;
        updated += installed.count;
        failures.extend(
            installed
                .failed
                .into_iter()
                .map(|name| format!("{name} ({})", plan.label)),
        );
        kendex_core::drift::snapshot::record(env, &plan.scope)?;
    }
    offer_to_commit(env, plans)?;
    if failures.is_empty() {
        say(&match updated {
            0 => "all pi packages up to date".to_owned(),
            count => format!("updated {count} package(s)"),
        });
        return Ok(());
    }
    Err(format!("update failed for: {}", failures.join(", ")).into())
}

/// What one scope's install pass did: how many packages landed, and the
/// names of the ones that did not, each already said with its cause.
struct Installed {
    count: usize,
    failed: Vec<String>,
}

/// Install every row the plan marks stale or missing, recording each
/// install as it completes and, once every one landed, the declared
/// packages the scope already held. A failed install keeps its provenance
/// and no completion, so the next pass finds it stale again.
fn install_rows(env: &Env, plan: &ScopePlan) -> Result<Installed, Box<dyn std::error::Error>> {
    let mut installed = Installed {
        count: 0,
        failed: Vec::new(),
    };
    for row in &plan.rows {
        let (source_dir, verb) = match &row.status {
            Status::Stale { source_dir } => (source_dir, "updated"),
            Status::Missing { source_dir } => (source_dir, "installed"),
            _ => continue,
        };
        pi_ext::clear_install_completion(env, &plan.scope, &row.name)?;
        match pi_ext::install(env, &plan.root, source_dir) {
            Ok(outcome) => {
                record_pi_installs(env, plan, Some(&row.name))?;
                installed.count += 1;
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
                say(&format!("  failed {}: {}", row.name, error));
                installed.failed.push(row.name.clone());
            }
        }
    }
    if installed.failed.is_empty() {
        record_pi_installs(env, plan, None)?;
    }
    Ok(installed)
}

/// The commit offer, made here because this verb writes into a project's
/// `.pi` directory without going through a plan, and so is not reached by
/// the seam in `engine_common::apply_report` that every other verb writes
/// through.
///
/// The paths the offer covers are the ones the engine renders in that
/// project, which only a plan names — so one is derived here for that
/// alone. A scope whose plan will not derive gets no offer: the writes
/// above still stand, and nothing about them is claimed.
fn offer_to_commit(env: &Env, plans: &[ScopePlan]) -> CliResult {
    for plan in plans {
        if !matches!(plan.scope, Scope::Project { .. }) {
            continue;
        }
        let Ok(report) = kendex_core::engine::plan_apply(
            env,
            &plan.scope,
            &kendex_core::engine::PlanOptions::default(),
        ) else {
            continue;
        };
        super::commit_offer::after_writing(env, &plan.scope, &report.generated)?;
    }
    Ok(())
}

fn record_pi_installs(env: &Env, plan: &ScopePlan, completed: Option<&str>) -> CliResult {
    let Some(manifest) = manifest::load_current(&manifest::manifest_path(env, &plan.scope))? else {
        return Ok(());
    };
    let path = kendex_core::lock::lock_path(env, &plan.scope);
    let mut lock = kendex_core::lock::load(&path)?;
    let before = lock.clone();
    let drift = match completed {
        Some(name) => pi_ext::record_matching_name(env, &plan.scope, &manifest, &mut lock, name)?,
        None => pi_ext::record_matching_manifest(
            env,
            &plan.scope,
            &manifest,
            &mut lock,
            pi_ext::RecordBasis::Recorded,
        )?,
    };
    if lock != before {
        kendex_core::lock::save(&path, &lock)?;
    }
    for row in drift {
        say(&format!("  ! {}: {}", row.name, row.detail));
    }
    Ok(())
}
