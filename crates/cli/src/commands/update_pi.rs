use std::path::{Path, PathBuf};

use kendex_core::decision::{PiChange, PiSettle};
use kendex_core::engine::PlanOptions;
use kendex_core::env::Env;
use kendex_core::manifest::ManifestFile;
use kendex_core::model::Scope;
use kendex_core::process::Hardened;
use kendex_core::{manifest, pi_ext, settings};

use super::{CliResult, resolve_scopes_at};
use crate::scope::ScopeFilter;
use crate::ui::{self, Span, Style};

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

/// Packages eligible for settlement, split at the process boundary.
enum Settlement {
    Copy { status: Status, change: PiChange },
    Process,
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
    notes: Vec<(String, String)>,
    /// Second copies of declared packages Pi loads from an `extensions/`
    /// directory, this root's or the other root Pi loads with it in this
    /// session, and the roots or names that would not read. Reported,
    /// never moved: the install below still lands the managed copy, and
    /// the entry in the way is the person's to move. Folded across the
    /// run's plans before printing (`ShadowScan::fold`), so one copy is
    /// one block however many scopes declare its package.
    shadows: pi_ext::ShadowScan,
}

/// Compare every installed Pi package against the source it came from and
/// reinstall the ones that fell behind, in the project `target` names
/// where it names one. A named project is registered as `apply` and
/// `refresh` register theirs: the refusal asked before the first write,
/// the registration once the write got through
/// (`project::register_target`), and, in a run that fails, for each scope
/// a package landed in before it did.
pub fn run(
    env: &Env,
    filter: ScopeFilter,
    target: &crate::flags::ProjectTargetFlag,
    check: bool,
) -> CliResult {
    let settings = settings::load(env)?;
    let scopes = resolve_scopes_at(env, filter, target.path())?;
    let registering = match check {
        true => super::project::Registering::Nothing,
        false => super::project::target_registrable(env, target, &scopes)?,
    };
    for scope in &scopes {
        if let Err(error) =
            kendex_core::engine::check_catalog_compatibility(env, scope, &PlanOptions::current())
            && error.is_catalog_compatibility()
        {
            return Err(error.into());
        }
    }
    let _guards = (!check)
        .then(|| kendex_core::apply::lock_scopes_for_write(env, &scopes))
        .transpose()?;
    let mut plans = plan_scopes(env, &settings, &scopes)?;

    let style = ui::style();
    if plans.is_empty() {
        ui::stderr(&style.summary(ui::Status::Done, "no place checked installs for Pi"));
        return Ok(());
    }
    pi_ext::ShadowScan::fold(plans.iter_mut().map(|plan| &mut plan.shadows));
    for plan in &plans {
        print(plan_lines(&style, plan));
    }

    if check {
        let pending = plans.iter().flat_map(|p| &p.rows).filter(updatable).count();
        if pending > 0 {
            ui::stderr(&style.summary(
                ui::Status::Decision,
                &format!(
                    "{pending} package(s) can be updated — run without --check to update them"
                ),
            ));
        }
        if plans.iter().any(|plan| !plan.notes.is_empty()) {
            return Err("Pi packages not evaluated".into());
        }
        return Ok(());
    }
    let mut wrote = Vec::new();
    if let Err(error) = update(env, &plans, &mut wrote) {
        // The packages that landed are on disk whatever failed beside
        // them, so their project is listed as `apply` lists one whose
        // effects step failed after its write; a registry that refuses is
        // said beside the failure it did not cause.
        for scope in wrote {
            if let Err(refused) = super::project::register_target(env, &registering, scope) {
                ui::stderr(&style.refusal("warning: ", refused.as_ref()));
            }
        }
        return Err(error);
    }
    for plan in &plans {
        super::project::register_target(env, &registering, &plan.scope)?;
    }
    Ok(())
}

/// The plan of every scope the run reached that has a Pi root or declares
/// a package, each install guard checking the run's other scopes too
/// (`pi_ext::paired_roots`).
fn plan_scopes(
    env: &Env,
    settings: &settings::AppSettings,
    scopes: &[Scope],
) -> Result<Vec<ScopePlan>, Box<dyn std::error::Error>> {
    let mut plans = Vec::new();
    for scope in scopes {
        let (root, other_roots) = pi_ext::paired_roots(env, settings, scope, scopes);
        if root.is_dir() || scope_declares_extensions(env, scope) {
            let (_, loaded_with) = pi_ext::session_roots(env, settings, scope);
            plans.push(plan_scope(env, scope, root, &other_roots, &loaded_with)?);
        }
    }
    Ok(plans)
}

fn updatable(row: &&Row) -> bool {
    matches!(row.status, Status::Stale { .. } | Status::Missing { .. })
}

/// The declared packages `settle_scope` would install in this scope, read
/// the way it reads them and writing nothing: what a verb shows before it
/// asks for the yes that lets the settle write, and the names it then
/// hands the settle. `options` are the verb's plan options, so each
/// package is read at the commit that plan reads it at; `targeted` the
/// scopes the verb writes, whose roots the install guard checks
/// (`pi_ext::paired_roots`).
pub(super) fn pending_settle(
    env: &Env,
    scope: &Scope,
    options: &PlanOptions,
    targeted: &[Scope],
) -> Result<Vec<PiSettle>, Box<dyn std::error::Error>> {
    let settings = settings::load(env)?;
    let (root, other_roots) = pi_ext::paired_roots(env, &settings, scope, targeted);
    Ok(settleable(env, scope, &root, &other_roots, options)?
        .into_iter()
        .filter_map(|(name, settlement)| match settlement {
            Settlement::Copy { change, .. } => Some(PiSettle { name, change }),
            Settlement::Process => None,
        })
        .collect())
}

/// Packages left out only because refresh may not run an install process.
/// All other settlement checks still apply, including completed bytes and origin.
pub(super) fn deferred_settle(
    env: &Env,
    scope: &Scope,
    options: &PlanOptions,
    targeted: &[Scope],
) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let settings = settings::load(env)?;
    let (root, other_roots) = pi_ext::paired_roots(env, &settings, scope, targeted);
    Ok(settleable(env, scope, &root, &other_roots, options)?
        .into_iter()
        .filter_map(|(name, settlement)| match settlement {
            Settlement::Copy { .. } => None,
            Settlement::Process => Some(name),
        })
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
/// Says what it installed and returns the names that landed: the plan the
/// caller derives next reports every package still unsettled as drift, and
/// that row is the run's failure. Only the scope lock and the install record
/// can stop the scope, and a stop still hands back what landed before it,
/// since those packages are on disk whatever the record says. The lock is
/// held for the install alone; the caller's own write takes it again.
pub fn settle_scope(
    env: &Env,
    scope: &Scope,
    names: &[String],
    options: &PlanOptions,
    targeted: &[Scope],
) -> Result<Vec<String>, SettleStopped> {
    let mut installed = Installed::default();
    match settle_rows(env, scope, names, options, targeted, &mut installed) {
        Ok(()) => Ok(installed.landed),
        Err(error) => Err(SettleStopped {
            landed: installed.landed,
            error,
        }),
    }
}

/// A settle that stopped on `error`, and the packages that landed before
/// it did.
#[derive(Debug)]
pub struct SettleStopped {
    pub landed: Vec<String>,
    pub error: Box<dyn std::error::Error>,
}

fn settle_rows(
    env: &Env,
    scope: &Scope,
    names: &[String],
    options: &PlanOptions,
    targeted: &[Scope],
    installed: &mut Installed,
) -> CliResult {
    let settings = settings::load(env)?;
    let (root, other_roots) = pi_ext::paired_roots(env, &settings, scope, targeted);
    let _guard = kendex_core::apply::lock_scopes_for_write(env, std::slice::from_ref(scope))?;
    let rows = settleable(env, scope, &root, &other_roots, options)?
        .into_iter()
        .filter(|(name, _)| names.contains(name))
        .filter_map(|(name, settlement)| match settlement {
            Settlement::Copy { status, .. } => Some(Row {
                version: installed_version(&root, &name),
                name,
                status,
            }),
            Settlement::Process => None,
        })
        .collect();
    let plan = ScopePlan {
        scope: scope.clone(),
        label: scope.label(),
        root,
        rows,
        notes: Vec::new(),
        shadows: pi_ext::ShadowScan::default(),
    };
    install_rows(env, &plan, options, installed)
}

/// What a settle may install, decided once and here: a declared package
/// whose source resolves, which no other root Pi loads already registers
/// under this or an earlier name, whose own root holds no copy under an
/// earlier name either; and either the
/// install record does not hold it at all, which is what a fresh clone
/// carries, and its installed copy is absent or byte-equal to that source
/// (`Missing`), or the record holds it from the same origin, its installed
/// copy is still the bytes that record completed, and the source moved
/// away from them (`Stale`), or the record does not hold it and the version
/// 10 record a recovery moved aside proves the installed copy as it sits
/// (`engine::version_10_pi_copy`), which is `Stale` the same way. `pi_ext::install` runs `npm ci` with a package
/// lock, or `npm install` without one, for a
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
/// only the record's. Each package's source is read at the commit a plan
/// under `options` reads it at.
fn settleable(
    env: &Env,
    scope: &Scope,
    root: &Path,
    other_roots: &[PathBuf],
    options: &PlanOptions,
) -> Result<Vec<(String, Settlement)>, Box<dyn std::error::Error>> {
    let Ok(ManifestFile::Current(manifest)) = manifest::load(&manifest::manifest_path(env, scope))
    else {
        return Ok(Vec::new());
    };
    if manifest.pi_extensions.is_empty() {
        return Ok(Vec::new());
    }
    let lock = kendex_core::lock::load(&kendex_core::lock::lock_path(env, scope))?;
    let manifest =
        kendex_core::engine::held_declarations(env, scope, &manifest, &lock, options)?.manifest;
    let mut found = Vec::new();
    for (name, decl) in &manifest.pi_extensions {
        let key = kendex_core::lock::entry_key(
            kendex_core::model::ItemKind::PiExtension,
            name,
            kendex_core::model::HarnessId::Pi,
        );
        // Two different questions. The first is package identity across
        // the paired roots, which folds the rename family. The second is
        // the family's OTHER spellings at this scope's own root, the
        // left-over an older kendex installed under a name this one no
        // longer uses. That probe excludes the declared spelling itself:
        // a bare `duplicate_elsewhere` against the own root would match
        // the copy the settle is for and skip every correctly installed
        // package.
        if pi_ext::duplicate_elsewhere(name, other_roots).is_some()
            || pi_ext::family(name)
                .iter()
                .filter(|other| **other != name)
                .any(|other| pi_ext::installed_under(root, other))
        {
            continue;
        }
        // Nothing installs a retired package again (`Resolved::Retired`).
        let package = match pi_ext::resolve_declared(env, scope, &manifest, name, decl) {
            Ok(pi_ext::Resolved::Ships(package)) => package,
            Err(error) if error.is_catalog_compatibility() => return Err(error.into()),
            Ok(pi_ext::Resolved::Retired { .. }) | Err(_) => continue,
        };
        let existing = lock.entries.get(&key);
        let basis = match existing {
            Some(_) => pi_ext::RecordBasis::Recorded,
            None => pi_ext::RecordBasis::MatchedBytes,
        };
        let installed = pi_ext::declared_state(root, name, &package, existing, basis);
        let source_dir = package.source_dir.clone();
        // The source a `Stale` copy was installed from, as its record names it.
        let (status, installed_from) = match (existing, installed) {
            (None, Ok(pi_ext::PackageState::Missing | pi_ext::PackageState::Current { .. })) => {
                (Status::Missing { source_dir }, None)
            }
            (None, Ok(pi_ext::PackageState::Different)) => {
                let unedited_source = matches!(
                    pi_ext::package_hash(&package.source_dir),
                    Ok(Some(source_hash)) if matches!(
                        pi_ext::installed_state(root, name, Some(&source_hash)),
                        Ok(pi_ext::PackageState::Current { .. })
                    )
                );
                if unedited_source {
                    (Status::Missing { source_dir }, None)
                } else if let Ok(Some(copy)) =
                    kendex_core::engine::version_10_pi_copy(env, scope, &lock, name)
                {
                    // An unedited copy a version 10 build installed, whose
                    // source moved on: the recovery's record has no entry
                    // for it, and that record's byte proof stands in.
                    (Status::Stale { source_dir }, Some(copy.installed_from))
                } else {
                    continue;
                }
            }
            (Some(entry), Ok(pi_ext::PackageState::Different))
                if pi_ext::check_origin(name, &package, Some(entry)).is_ok()
                    && matches!(
                        pi_ext::installed_state(root, name, entry.rendered_hash.as_deref()),
                        Ok(pi_ext::PackageState::Current { .. })
                    ) =>
            {
                let from = entry.source_commit.as_ref().unwrap_or(&entry.source_hash);
                (Status::Stale { source_dir }, Some(from.clone()))
            }
            (Some(_), _) | (_, Err(_)) => continue,
        };
        let settlement = match pi_ext::declares_runtime_deps(&package.source_dir) {
            Ok(false) => {
                let change = match installed_from {
                    None => PiChange::Missing,
                    Some(from) => PiChange::Stale {
                        from_version: installed_version(root, name),
                        to_version: pi_ext::read(&package.source_dir)?.version,
                        from,
                        to: match package.source_commit {
                            Some(commit) => commit,
                            None => pi_ext::package_hash(&package.source_dir)?
                                .ok_or("Pi source package disappeared before consent")?,
                        },
                    },
                };
                Settlement::Copy { status, change }
            }
            Ok(true) => Settlement::Process,
            Err(_) => continue,
        };
        found.push((name.clone(), settlement));
    }
    Ok(found)
}

fn scope_declares_extensions(env: &Env, scope: &Scope) -> bool {
    match manifest::load(&manifest::manifest_path(env, scope)) {
        Ok(ManifestFile::Current(manifest)) => !manifest.pi_extensions.is_empty(),
        Ok(ManifestFile::Absent) => false,
        Err(_) => true,
    }
}

/// `other_roots` is every root the install guard checks against
/// (`pi_ext::paired_roots`); `loaded_with` the one root Pi loads beside
/// this scope in this session (`pi_ext::session_roots`).
fn plan_scope(
    env: &Env,
    scope: &Scope,
    root: PathBuf,
    other_roots: &[PathBuf],
    loaded_with: &[PathBuf],
) -> Result<ScopePlan, Box<dyn std::error::Error>> {
    let mut notes = Vec::new();
    let (declared, resolved) = declared_sources(env, scope, &mut notes)?;
    let lock = kendex_core::lock::load(&kendex_core::lock::lock_path(env, scope))?;
    let mut rows = Vec::new();
    let mut sourced = std::collections::BTreeSet::new();
    for (name, resolution) in resolved {
        if matches!(resolution, Ok(pi_ext::Resolved::Ships(_))) {
            sourced.insert(name.clone());
        }
        let key = kendex_core::lock::entry_key(
            kendex_core::model::ItemKind::PiExtension,
            &name,
            kendex_core::model::HarnessId::Pi,
        );
        let status = match pi_ext::admit(
            &root,
            other_roots,
            &name,
            resolution,
            lock.entries.get(&key),
            pi_ext::RecordBasis::Recorded,
        ) {
            // Nothing installs a retired package again.
            pi_ext::Admission::Retired => continue,
            pi_ext::Admission::Current { .. } => Status::Current,
            pi_ext::Admission::Install { package, change } => match change {
                pi_ext::Install::Missing => Status::Missing {
                    source_dir: package.source_dir,
                },
                pi_ext::Install::Stale => Status::Stale {
                    source_dir: package.source_dir,
                },
            },
            pi_ext::Admission::LoadedElsewhere { installed, at } => Status::Blocked {
                reason: format!(
                    "blocked: {installed} would register twice. Pi loads your user and project package lists together; loading this package twice prevents Pi from starting. Keep either copy and remove the other before updating. User packages: {}; project packages: {}",
                    match scope {
                        Scope::Global => root.as_path(),
                        Scope::Project { .. } => at.as_path(),
                    }
                    .display(),
                    match scope {
                        Scope::Global => at.as_path(),
                        Scope::Project { .. } => root.as_path(),
                    }
                    .display()
                ),
            },
            pi_ext::Admission::OriginRefused(error) => return Err(error.into()),
            pi_ext::Admission::NotEvaluated(error) => {
                notes.push((name, error.to_string()));
                continue;
            }
        };
        rows.push(Row {
            version: installed_version(&root, &name),
            name,
            status,
        });
    }
    // Every declared name, whether or not its source resolved: the copy
    // under `extensions/` runs whatever state the managed one is in.
    let shadows = pi_ext::shadows(&root, loaded_with, &declared);
    for name in pi_ext::list_installed(&root)? {
        if !sourced.contains(&name) {
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
        shadows,
    })
}

/// What a scope's catalogs answer for each declared Pi extension, by name.
type Resolutions = Vec<(String, kendex_core::error::Result<pi_ext::Resolved>)>;

/// Every declared Pi extension by name, and what its catalog answers for
/// each, which `pi_ext::admit` judges: a source that would not resolve is
/// a note there, so the rest of the scope still updates. A catalog
/// compatibility refusal stops the scope here instead. The name list keeps
/// every declaration, for the checks that read what sits on disk whatever
/// the source says.
fn declared_sources(
    env: &Env,
    scope: &Scope,
    notes: &mut Vec<(String, String)>,
) -> kendex_core::error::Result<(Vec<String>, Resolutions)> {
    let path = manifest::manifest_path(env, scope);
    let manifest = match manifest::load(&path) {
        Ok(ManifestFile::Current(manifest)) => manifest,
        Ok(_) => return Ok((Vec::new(), Vec::new())),
        Err(error) => {
            notes.push(("manifest".to_owned(), error.to_string()));
            return Ok((Vec::new(), Vec::new()));
        }
    };
    let mut found = Vec::new();
    for (name, decl) in &manifest.pi_extensions {
        match pi_ext::resolve_declared(env, scope, &manifest, name, decl) {
            Err(error) if error.is_catalog_compatibility() => return Err(error),
            resolution => found.push((name.clone(), resolution)),
        }
    }
    Ok((manifest.pi_extensions.keys().cloned().collect(), found))
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

/// Which stream a drawn block goes to: the package rows are the verb's
/// answer and go to stdout, everything said about them to stderr.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Stream {
    Out,
    Err,
}

fn print(drawn: Vec<(Stream, Vec<String>)>) {
    for (stream, lines) in drawn {
        match stream {
            Stream::Out => ui::stdout(&lines),
            Stream::Err => ui::stderr(&lines),
        }
    }
}

/// One scope's plan: its place, a row per package, then what could not be
/// read and the second copies Pi would load beside a managed one.
fn plan_lines(style: &Style, plan: &ScopePlan) -> Vec<(Stream, Vec<String>)> {
    let mut drawn = vec![(
        Stream::Err,
        style.report_heading(
            match plan.scope {
                Scope::Global => "global",
                Scope::Project { .. } => "project",
            },
            &plan.label,
            &plan.root.display().to_string(),
            plan.rows.len(),
            ui::Status::Notice,
        ),
    )];
    if plan.rows.is_empty() {
        drawn.push((
            Stream::Err,
            style.report_detail(&[Span::Prose("no pi packages installed")], "  "),
        ));
    }
    drawn.push((
        Stream::Out,
        plan.rows
            .iter()
            .flat_map(|row| {
                style.report_package(
                    row_status(row),
                    &row.name,
                    row.version.as_deref(),
                    target(row),
                    &describe(row),
                )
            })
            .collect(),
    ));
    let mut said = Vec::new();
    for (name, reason) in &plan.notes {
        said.extend(style.report_keyed(
            ui::Status::Failed,
            &format!("not-evaluated={name} scope={} : {reason}", plan.label),
            "  ! ",
            &format!("{name}: kendex could not check it"),
            reason,
        ));
    }
    for error in &plan.shadows.errors {
        said.extend(style.report_row(
            ui::Status::Failed,
            &[Span::Prose(&format!(
                "could not check for a second copy — {error}"
            ))],
            "  ! ",
        ));
    }
    for shadow in &plan.shadows.found {
        let lines = shadow.lines(kendex_core::names::shown);
        said.extend(style.report_row(ui::Status::Decision, &[Span::Prose(&lines.key)], ""));
        for line in [&lines.managed, &lines.shadow, &lines.remedy] {
            said.extend(style.report_detail(&[Span::Prose(line)], "  "));
        }
    }
    drawn.push((Stream::Err, said));
    drawn
}

/// What a package's row needs from the person, decided by its status: a
/// package blocked from installing is a failure, one this verb installs is
/// a change waiting on the run, and one Pi or nothing here supplies is a
/// notice.
fn row_status(row: &Row) -> ui::Status {
    use kendex_core::decision::Need;
    match &row.status {
        Status::Current => ui::Status::Done,
        Status::Stale { .. } | Status::Missing { .. } => ui::Status::of(Need::Decision),
        Status::Blocked { .. } => ui::Status::of(Need::Blocked),
        Status::Unsourced | Status::Npm { .. } => ui::Status::of(Need::Notice),
    }
}

/// The version an npm package can move to, where it differs from the one
/// installed; kendex settles every other package itself.
fn target(row: &Row) -> Option<&str> {
    match &row.status {
        Status::Npm {
            latest: Some(latest),
        } if row.version.as_deref() != Some(latest.as_str()) => Some(latest),
        _ => None,
    }
}

fn describe(row: &Row) -> String {
    match &row.status {
        Status::Current => "up to date".to_owned(),
        Status::Stale { .. } => "stale (package or install record differs)".to_owned(),
        Status::Missing { .. } => "not installed yet".to_owned(),
        Status::Blocked { reason } => reason.clone(),
        Status::Unsourced => "nothing this place lists supplies it".to_owned(),
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

/// Install what each plan marks, and say how the run ended. `wrote` gains
/// every scope a package landed in, whatever the run returns: a failure
/// after a landed install still leaves that install on disk. A scope whose
/// pass stops, on its install record or its lock, is one failure of the
/// run: what landed before the stop is counted, and the scopes after it
/// still update, so the closing line and the commit offer cover every
/// package on disk.
fn update<'p>(env: &Env, plans: &'p [ScopePlan], wrote: &mut Vec<&'p Scope>) -> CliResult {
    let style = ui::style();
    let mut updated = 0usize;
    let mut failures: Vec<String> = Vec::new();
    for plan in plans {
        failures.extend(
            plan.notes
                .iter()
                .map(|(name, _)| format!("{name} ({}): not evaluated", plan.label)),
        );
        // No resolved declaration can complete a record here. In particular,
        // an unreadable manifest must not stop updates in the other scopes.
        if !plan.notes.is_empty()
            && !plan.rows.iter().any(|row| {
                matches!(
                    row.status,
                    Status::Current | Status::Stale { .. } | Status::Missing { .. }
                )
            })
        {
            continue;
        }
        let mut installed = Installed::default();
        let pass = install_rows(env, plan, &PlanOptions::current(), &mut installed);
        if !installed.landed.is_empty() {
            wrote.push(&plan.scope);
        }
        updated += installed.landed.len();
        failures.extend(
            installed
                .failed
                .into_iter()
                .map(|name| format!("{name} ({})", plan.label)),
        );
        if let Err(error) = pass {
            failures.push(format!("{}: {error}", plan.label));
            continue;
        }
        // The snapshot is what the next session-start check reads instead
        // of redoing this pass; one that will not derive is a warning, as
        // refresh says it, since the packages it describes are on disk.
        if let Err(error) = kendex_core::drift::snapshot::record(env, &plan.scope) {
            ui::report::warning(&format!("snapshot not derived ({error})"));
        }
    }
    // Every replaced copy went to the trash with its dependency tree;
    // the pass runs once every scope is written, before the closing line.
    super::engine_common::tidy_trash(env);
    // An offer that fails is one more failure of the run, said with the
    // others rather than in their place. A cancel at the offer still lets
    // the run say what it installed, and ends the run as a cancel only
    // where nothing else failed.
    failures.extend(offer_to_commit(env, plans));
    ui::stderr(&closing_lines(&style, updated, failures.is_empty()));
    match failures.is_empty() {
        true => Ok(()),
        false => Err(format!("update failed for: {}", failures.join(", ")).into()),
    }
}

/// The line a run that installed closes on: what landed, whatever failed
/// beside it, which the error after it names. A run that installed nothing
/// and failed closes on that error alone.
fn closing_lines(style: &Style, updated: usize, clean: bool) -> Vec<String> {
    match (updated, clean) {
        (0, true) => style.summary(ui::Status::Done, "all pi packages up to date"),
        (0, false) => Vec::new(),
        (count, _) => style.summary(ui::Status::Done, &format!("updated {count} package(s)")),
    }
}

/// What one scope's install pass did: the packages that landed, and the
/// names of the ones that did not, each already said with its cause.
#[derive(Default)]
struct Installed {
    landed: Vec<String>,
    failed: Vec<String>,
}

/// Install every row the plan marks stale or missing, recording each
/// install as it completes and, once every one landed, the declared
/// packages the scope already held. A failed install keeps its provenance
/// and no completion, so the next pass finds it stale again. The record
/// compares each package with its source read at the commit a plan under
/// `options` reads it at, the commit the plan's rows were installed from.
/// What landed is counted into `installed` and said as it lands, before
/// its record is written, so a pass that stops on an error, the record's
/// included, still says what it wrote.
fn install_rows(
    env: &Env,
    plan: &ScopePlan,
    options: &PlanOptions,
    installed: &mut Installed,
) -> CliResult {
    let declared = kendex_core::engine::ops::manifest_for_reading(env, &plan.scope)?;
    let lock = kendex_core::lock::load(&kendex_core::lock::lock_path(env, &plan.scope))?;
    let readings =
        kendex_core::engine::held_declarations(env, &plan.scope, &declared, &lock, options)?;
    let manifest = &readings.manifest;
    let style = ui::style();
    for row in &plan.rows {
        let (source_dir, verb) = match &row.status {
            Status::Stale { source_dir } => (source_dir, "updated"),
            Status::Missing { source_dir } => (source_dir, "installed"),
            _ => continue,
        };
        let decl = manifest
            .pi_extensions
            .get(&row.name)
            .ok_or_else(|| format!("planned Pi install '{}' has no declaration", row.name))?;
        pi_ext::clear_install_completion(env, &plan.scope, &row.name)?;
        match pi_ext::install(env, &plan.root, source_dir, decl.enabled) {
            Ok(outcome) => {
                installed.landed.push(row.name.clone());
                ui::stdout(
                    &style
                        .report_landed(&format!("{verb} {}", row.name), outcome.version.as_deref()),
                );
                for bin in &outcome.unbuilt_bins {
                    ui::stderr(&style.report_row(
                        ui::Status::Decision,
                        &[Span::Prose(&format!(
                            "{}: declared bin '{bin}' is missing; the package publisher must ship this file. Its command was not linked",
                            row.name
                        ))],
                        "  ! ",
                    ));
                }
                record_pi_installs(env, plan, &readings, Some(&row.name))?;
            }
            Err(error) => {
                ui::stderr(&style.report_row(
                    ui::Status::Failed,
                    &[Span::Prose(&format!("failed {}: {error}", row.name))],
                    "  ",
                ));
                installed.failed.push(row.name.clone());
            }
        }
    }
    if installed.failed.is_empty() {
        record_pi_installs(env, plan, &readings, None)?;
    }
    Ok(())
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
///
/// Each project whose offer fails is one failure, named by its scope, and
/// the next project is still offered, as `refresh` offers each scope.
fn offer_to_commit(env: &Env, plans: &[ScopePlan]) -> Vec<String> {
    let mut failures = Vec::new();
    for plan in plans {
        if !matches!(plan.scope, Scope::Project { .. }) {
            continue;
        }
        let Ok(report) = kendex_core::engine::plan_apply(
            env,
            &plan.scope,
            &kendex_core::engine::PlanOptions::current(),
        ) else {
            continue;
        };
        if let Err(error) = super::commit_offer::after_writing(
            env,
            &plan.scope,
            &report.generated,
            &kendex_core::commit_offer::Before::Untaken,
        ) {
            failures.push(format!("{}: {error}", plan.label));
        }
    }
    failures
}

fn record_pi_installs(
    env: &Env,
    plan: &ScopePlan,
    readings: &kendex_core::engine::HeldDeclarations<'_>,
    completed: Option<&str>,
) -> CliResult {
    let path = kendex_core::lock::lock_path(env, &plan.scope);
    let mut lock = kendex_core::lock::load(&path)?;
    let before = lock.clone();
    let drift = match completed {
        Some(name) => pi_ext::record_matching_name(
            env,
            &plan.scope,
            &readings.manifest,
            &mut lock,
            Some(&readings.selectors),
            name,
        )?,
        None => pi_ext::record_matching_manifest(
            env,
            &plan.scope,
            &readings.manifest,
            &mut lock,
            Some(&readings.selectors),
            pi_ext::RecordBasis::Recorded,
            None,
        )?,
    };
    if lock != before {
        kendex_core::lock::save(&path, &lock)?;
    }
    let style = ui::style();
    for row in drift {
        ui::stderr(&style.report_row(
            ui::Status::Decision,
            &[Span::Prose(&format!("{}: {}", row.name, row.detail))],
            "  ! ",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ui::testing::{plain, rich, tagged};

    fn row(name: &str, version: Option<&str>, status: Status) -> Row {
        Row {
            name: name.to_owned(),
            version: version.map(str::to_owned),
            status,
        }
    }

    fn drawn(style: &Style, plan: &ScopePlan) -> Vec<String> {
        plan_lines(style, plan)
            .into_iter()
            .flat_map(|(stream, lines)| {
                lines.into_iter().map(move |line| {
                    format!(
                        "{}{line}",
                        match stream {
                            Stream::Out => "out|",
                            Stream::Err => "err|",
                        }
                    )
                })
            })
            .collect()
    }

    fn plan(rows: Vec<Row>, notes: Vec<(String, String)>) -> ScopePlan {
        ScopePlan {
            scope: Scope::Global,
            label: "user".into(),
            root: PathBuf::from("/home/a/.pi/agent"),
            rows,
            notes,
            shadows: pi_ext::ShadowScan::default(),
        }
    }

    /// A scope's plan in both renderings, a row per status the verb reads
    /// and a package it could not evaluate. Plain keeps the columns on
    /// stdout, their `-` for no version, and the scope and the
    /// `not-evaluated=` key on stderr; rich marks each row with what it
    /// needs: done, an install this run makes, a package blocked from
    /// installing, and a notice for what kendex leaves alone. Rich leaves a
    /// missing version off and says the unevaluated package in words.
    #[test]
    fn a_plan_draws_each_status_with_what_it_needs() {
        let source_dir = PathBuf::from("/catalog/pi-extensions/pi-widgets");
        let full = plan(
            vec![
                row("pi-current", Some("1.0.0"), Status::Current),
                row(
                    "pi-stale",
                    Some("1.0.0"),
                    Status::Stale {
                        source_dir: source_dir.clone(),
                    },
                ),
                row("pi-missing", None, Status::Missing { source_dir }),
                row(
                    "pi-twice",
                    Some("1.0.0"),
                    Status::Blocked {
                        reason: "blocked: pi-twice would register twice".into(),
                    },
                ),
                row("pi-left", Some("0.1.0"), Status::Unsourced),
                row(
                    "pi-npm",
                    Some("1.0.0"),
                    Status::Npm {
                        latest: Some("2.0.0".into()),
                    },
                ),
            ],
            vec![("pi-broken".into(), "source cat is not readable".into())],
        );
        // A project's label is its root and its place the root's `.pi`:
        // plain says both on the one line scripts read, and rich puts the
        // place on its own line, so neither path runs past the width.
        let root = PathBuf::from("/home/a/dev/a-project-whose-folder-name-is-long");
        let project = ScopePlan {
            scope: Scope::Project { root: root.clone() },
            label: root.display().to_string(),
            root: root.join(".pi"),
            ..plan(Vec::new(), Vec::new())
        };
        // The join takes the platform's separator, which the drawn place
        // keeps.
        let place = project.root.display();
        let project_plain = format!("err|{} ({place})", root.display());
        let project_rich = format!("err|    <90>{place}</>");
        let rows: [(&ScopePlan, &[&str], &[&str]); 3] = [
            (
                &full,
                &[
                    "err|user (/home/a/.pi/agent)",
                    "out|  pi-current                         1.0.0                  up to date",
                    "out|  pi-stale                           1.0.0                  stale (package or install record differs)",
                    "out|  pi-missing                         -                      not installed yet",
                    "out|  pi-twice                           1.0.0                  blocked: pi-twice would register twice",
                    "out|  pi-left                            0.1.0                  nothing this place lists supplies it",
                    "out|  pi-npm                             1.0.0 -> 2.0.0         npm, update available",
                    "err|  ! not-evaluated=pi-broken scope=user : source cat is not readable",
                ],
                &[
                    "err|",
                    "err|<1;36>global</>  <90>6</>",
                    "err|    <90>/home/a/.pi/agent</>",
                    "out|  <32>✓</> pi-current 1.0.0",
                    "out|    <90>up to date</>",
                    "out|  <33>!</> pi-stale 1.0.0",
                    "out|    <90>stale (package or install record differs)</>",
                    "out|  <33>!</> pi-missing",
                    "out|    <90>not installed yet</>",
                    "out|  <31>✗</> pi-twice 1.0.0",
                    "out|    <90>blocked: pi-twice would register twice</>",
                    "out|  <36>•</> pi-left 0.1.0",
                    "out|    <90>nothing this place lists supplies it</>",
                    "out|  <36>•</> pi-npm 1.0.0 → 2.0.0",
                    "out|    <90>npm, update available</>",
                    "err|  <31>✗</> pi-broken: kendex could not check it",
                    "err|    <90>source cat is not readable</>",
                ],
            ),
            (
                &plan(Vec::new(), Vec::new()),
                &[
                    "err|user (/home/a/.pi/agent)",
                    "err|  no pi packages installed",
                ],
                &[
                    "err|",
                    "err|<1;36>global</>  <90>0</>",
                    "err|    <90>/home/a/.pi/agent</>",
                    "err|    <90>no pi packages installed</>",
                ],
            ),
            (
                &project,
                &[&project_plain, "err|  no pi packages installed"],
                &[
                    "err|",
                    "err|<1;36>project</>  <90>0</>",
                    &project_rich,
                    "err|    <90>no pi packages installed</>",
                ],
            ),
        ];
        for (plan, want_plain, want_rich) in rows {
            assert_eq!(drawn(&plain(), plan), want_plain);
            assert_eq!(tagged(&drawn(&rich(80), plan)), want_rich);
        }
    }

    /// A second copy's paths are what a person copies to make the move the
    /// warning asks for, so rich output narrower than each path still
    /// draws every one whole on a line of its own. The shadow path holds
    /// the extensions path, so only a line equal to a path proves it whole.
    #[test]
    fn a_second_copy_keeps_its_paths_whole_at_any_width() {
        let root = PathBuf::from("/home/a/.pi/agent");
        let extensions = root.join("extensions-left-by-an-earlier-installer");
        let copy = pi_ext::ShadowPackage {
            name: "pi-widgets".into(),
            managed: root.join("packages/pi-widgets-managed-by-kendex"),
            managed_version: Some("2.0.0".into()),
            shadow: extensions.join("pi-widgets-old-copy"),
            shadow_version: None,
            extensions,
        };
        let paths =
            [&copy.managed, &copy.shadow, &copy.extensions].map(|path| path.display().to_string());
        let shadowed = ScopePlan {
            shadows: pi_ext::ShadowScan {
                found: vec![copy],
                errors: Vec::new(),
            },
            ..plan(Vec::new(), Vec::new())
        };
        let lines: Vec<String> = drawn(&rich(30), &shadowed)
            .iter()
            .map(|line| console::strip_ansi_codes(line).into_owned())
            .collect();
        for path in paths {
            assert!(
                lines
                    .iter()
                    .any(|line| line.trim_start_matches("err|").trim() == path),
                "{path} is broken across {lines:#?}"
            );
        }
    }

    /// Each package as it lands, then the line the run closes on: what
    /// landed whatever failed beside it, the clean line where nothing
    /// needed installing, and nothing where nothing landed and the error
    /// the run ends on says why.
    #[test]
    fn landed_packages_and_the_closing_line_count_what_was_installed() {
        let rows: [(usize, bool, &[&str], &[&str]); 4] = [
            (
                0,
                true,
                &["all pi packages up to date"],
                &["", "<32>✓</> <1>all pi packages up to date</>"],
            ),
            (0, false, &[], &[]),
            (
                2,
                true,
                &["updated 2 package(s)"],
                &["", "<32>✓</> <1>updated 2 package(s)</>"],
            ),
            (
                2,
                false,
                &["updated 2 package(s)"],
                &["", "<32>✓</> <1>updated 2 package(s)</>"],
            ),
        ];
        for (updated, clean, want_plain, want_rich) in rows {
            assert_eq!(closing_lines(&plain(), updated, clean), want_plain);
            assert_eq!(tagged(&closing_lines(&rich(80), updated, clean)), want_rich);
        }
        let landed = |style: &Style| {
            let mut lines = style.report_landed("updated pi-stale", Some("2.0.0"));
            lines.extend(style.report_landed("installed pi-missing", None));
            lines
        };
        assert_eq!(
            landed(&plain()),
            ["  updated pi-stale -> 2.0.0", "  installed pi-missing -> ?"]
        );
        assert_eq!(
            tagged(&landed(&rich(80))),
            [
                "  <32>✓</> updated pi-stale → 2.0.0",
                "  <32>✓</> installed pi-missing",
            ]
        );
    }

    #[test]
    #[allow(clippy::unwrap_used)]
    fn catalog_compatibility_failures_are_not_advisory_notes() {
        let temp = tempfile::tempdir().unwrap();
        let home = crate::test_util::rooted(&temp);
        let env = Env::host_rooted(&home);
        let project = home.join("consumer");
        let catalog = home.join("catalog");
        std::fs::create_dir_all(&project).unwrap();
        std::fs::create_dir_all(&catalog).unwrap();
        std::fs::write(catalog.join("kendex.toml"), "min_kendex = '999999.0.0'\n").unwrap();
        std::fs::write(
            project.join("kendex.toml"),
            format!(
                "schema = 7\n[sources.cat]\n{}\n[pi-extensions.fixture]\nsource = 'cat'\n",
                crate::test_util::source_path(&catalog)
            ),
        )
        .unwrap();
        let scope = Scope::Project { root: project };
        let mut notes = Vec::new();
        assert!(matches!(
            declared_sources(&env, &scope, &mut notes),
            Err(kendex_core::error::CoreError::CatalogNeedsEngine { .. })
        ));
        assert!(notes.is_empty());
    }

    /// A project `--project-path` names is on no projects list and is not
    /// the working directory: registration comes after the write, or never
    /// for a declined write, a linked work tree or a `--throwaway` folder.
    /// It already holds a package the personal scope also declares. Every
    /// reading of the personal scope that the run's scopes reach blocks its
    /// copy rather than install it, since Pi would load the package twice
    /// and not start: update-pi's plan, and refresh's settle and the names
    /// it asks about first.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn a_named_project_holding_a_package_blocks_its_personal_copy() {
        type Blocked = fn(&Env, &[Scope]) -> bool;
        let rows: [(&str, Blocked); 3] = [
            ("update-pi plan", |env, targeted| {
                let settings = settings::load(env).unwrap();
                let plans = plan_scopes(env, &settings, targeted).unwrap();
                let personal = plans
                    .iter()
                    .find(|plan| matches!(plan.scope, Scope::Global))
                    .unwrap();
                let row = personal
                    .rows
                    .iter()
                    .find(|row| row.name == "pi-twice")
                    .unwrap();
                matches!(row.status, Status::Blocked { .. })
            }),
            ("refresh pending settle", |env, targeted| {
                pending_settle(env, &Scope::Global, &PlanOptions::current(), targeted)
                    .unwrap()
                    .iter()
                    .all(|pending| pending.name != "pi-twice")
            }),
            ("refresh settle", |env, targeted| {
                let names = ["pi-twice".to_owned()];
                let options = PlanOptions::current();
                settle_scope(env, &Scope::Global, &names, &options, targeted).unwrap();
                let settings = settings::load(env).unwrap();
                let (root, _) = pi_ext::paired_roots(env, &settings, &Scope::Global, &[]);
                !pi_ext::installed_under(&root, "pi-twice")
            }),
        ];
        for (label, blocked) in rows {
            let temp = tempfile::tempdir().unwrap();
            let home = crate::test_util::rooted(&temp);
            let env = Env::host_rooted(&home);
            let catalog = home.join("catalog");
            let source = catalog.join("pi-extensions/pi-twice");
            std::fs::create_dir_all(&source).unwrap();
            std::fs::write(
                source.join("package.json"),
                r#"{"name":"pi-twice","version":"1.0.0","pi":{"extensions":["index.js"]}}"#,
            )
            .unwrap();
            std::fs::write(source.join("index.js"), "export const value = 1;\n").unwrap();
            let declared = format!(
                "schema = 7\n[sources.cat]\n{}\n[pi-extensions.pi-twice]\nsource = 'cat'\n",
                crate::test_util::source_path(&catalog)
            );
            let named = Scope::Project {
                root: home.join("named"),
            };
            for scope in [&named, &Scope::Global] {
                let path = manifest::manifest_path(&env, scope);
                std::fs::create_dir_all(path.parent().unwrap()).unwrap();
                std::fs::write(path, &declared).unwrap();
            }
            let targeted = [named.clone(), Scope::Global];
            let names = ["pi-twice".to_owned()];
            settle_scope(&env, &named, &names, &PlanOptions::current(), &targeted).unwrap();
            let settings = settings::load(&env).unwrap();
            assert!(
                settings.projects.is_empty(),
                "{label}: the project is on no list"
            );

            assert!(blocked(&env, &targeted), "{label}");
        }
    }

    /// Catalog declarations produce missing, recorded stale, and current copies.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn pending_consent_keeps_missing_and_stale_separate() {
        for scope_name in ["project", "user"] {
            let temp = tempfile::tempdir().unwrap();
            let home = crate::test_util::rooted(&temp);
            let env = Env::host_rooted(&home);
            let scope = match scope_name {
                "project" => Scope::Project {
                    root: home.join("project"),
                },
                "user" => Scope::Global,
                _ => unreachable!(),
            };
            let base = match &scope {
                Scope::Project { root } => root,
                Scope::Global => &home,
            };
            let source = base.join("catalog/pi-extensions/pi-consent");
            std::fs::create_dir_all(&source).unwrap();
            let path = manifest::manifest_path(&env, &scope);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, "schema = 7\n[sources.cat]\npath = 'catalog'\n[pi-extensions.pi-consent]\nsource = 'cat'\n").unwrap();
            std::fs::write(
                source.join("package.json"),
                r#"{"name":"pi-consent","version":"1.0.0","pi":{"extensions":["index.js"]}}"#,
            )
            .unwrap();
            std::fs::write(source.join("index.js"), "export const value = 1;\n").unwrap();
            let options = PlanOptions::current();
            let missing =
                pending_settle(&env, &scope, &options, std::slice::from_ref(&scope)).unwrap();
            assert_eq!(
                missing
                    .iter()
                    .map(|pending| pending.name.as_str())
                    .collect::<Vec<_>>(),
                ["pi-consent"]
            );
            assert_eq!(missing[0].change, PiChange::Missing);
            settle_scope(
                &env,
                &scope,
                &["pi-consent".into()],
                &options,
                std::slice::from_ref(&scope),
            )
            .unwrap();
            let from = pi_ext::package_hash(&source).unwrap().unwrap();
            std::fs::write(
                source.join("package.json"),
                r#"{"name":"pi-consent","version":"2.0.0","pi":{"extensions":["index.js"]}}"#,
            )
            .unwrap();
            let to = pi_ext::package_hash(&source).unwrap().unwrap();
            let stale =
                pending_settle(&env, &scope, &options, std::slice::from_ref(&scope)).unwrap();
            assert_eq!(
                stale
                    .iter()
                    .map(|pending| pending.name.as_str())
                    .collect::<Vec<_>>(),
                ["pi-consent"]
            );
            assert_eq!(
                stale[0].change,
                PiChange::Stale {
                    from_version: Some("1.0.0".into()),
                    to_version: Some("2.0.0".into()),
                    from,
                    to,
                }
            );
            settle_scope(
                &env,
                &scope,
                &["pi-consent".into()],
                &options,
                std::slice::from_ref(&scope),
            )
            .unwrap();
            assert!(
                pending_settle(&env, &scope, &options, std::slice::from_ref(&scope))
                    .unwrap()
                    .is_empty()
            );
        }
    }
}
