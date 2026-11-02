//! Carrier provenance and byte comparisons share one record builder.

use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::error::{CoreError, Result};

use super::{PackageState, RecordBasis, declared_state, find_by_package_name};

/// One declared Pi package resolved to the catalog bytes and provenance that
/// installation, verification, recovery, and report routing share.
#[derive(Debug, Clone)]
pub struct DeclaredPackage {
    pub source_dir: PathBuf,
    pub source: String,
    pub source_repo: String,
    pub source_commit: Option<String>,
    pub selector: Option<crate::lock::DeclaredSelector>,
}

/// Preserve provenance but clear completion before replacement destroys the
/// installed package. The caller holds the scope lock until installation ends.
pub fn clear_install_completion(env: &Env, scope: &crate::model::Scope, name: &str) -> Result<()> {
    let path = crate::lock::lock_path(env, scope);
    let mut lock = crate::lock::load(&path)?;
    let key = crate::lock::entry_key(
        crate::model::ItemKind::PiExtension,
        name,
        crate::model::HarnessId::Pi,
    );
    if let Some(entry) = lock.entries.get_mut(&key)
        && entry.rendered_hash.take().is_some()
    {
        crate::lock::save(&path, &lock)?;
    }
    Ok(())
}

/// What a Pi declaration's catalog answers for it.
#[derive(Debug, Clone)]
pub enum Resolved {
    Ships(DeclaredPackage),
    /// The catalog retired it (`[retired.pi-extensions]`), whether or not it
    /// still carries the package: nothing installs, settles or re-records
    /// it. The plan keeps or prunes what is recorded, as
    /// `PlanOptions::prune_retired` states, and holds a record another
    /// catalog wrote to invariant 4 by `source_repo`, as for any item.
    Retired {
        migration: String,
        source_repo: String,
    },
}

pub fn resolve_declared(
    env: &Env,
    scope: &crate::model::Scope,
    manifest: &crate::manifest::Manifest,
    name: &str,
    decl: &crate::manifest::ItemDecl,
) -> Result<Resolved> {
    let ready =
        crate::source::require_ready_at(env, scope, &decl.source, manifest, decl.rev.as_deref())?;
    let sealed = crate::source_read::SealedSource::open(&ready.root)?;
    let config = crate::source::source_config_for(&sealed, &ready.provenance)?;
    if let Some(migration) = config.retired(crate::model::ItemKind::PiExtension, name) {
        return Ok(Resolved::Retired {
            migration: migration.to_owned(),
            source_repo: ready.provenance,
        });
    }
    let direct = sealed.root().join("pi-extensions").join(name);
    let source_dir = if sealed.is_file(&direct.join("package.json")) {
        direct
    } else {
        find_by_package_name(&sealed, name)?.ok_or_else(|| CoreError::PiPackage {
            name: name.to_owned(),
            message: format!(
                "source '{}' no longer ships pi-extensions/{name}",
                decl.source
            ),
        })?
    };
    Ok(Resolved::Ships(DeclaredPackage {
        source_dir,
        source: decl.source.clone(),
        source_repo: ready.provenance,
        source_commit: ready.commit,
        selector: Some(crate::lock::DeclaredSelector::of(
            manifest,
            &decl.source,
            decl.rev.as_deref(),
        )),
    }))
}

/// What `update-pi` does with one declared package, decided here once for
/// the verb that installs it (`update-pi`'s plan), for the plans that name
/// it (`record_matching`), for the check that names it (`drift::report`)
/// and for the package's update standing (`package::updates`), so none of
/// them keeps a reading of its own.
#[derive(Debug)]
pub enum Admission {
    /// Its catalog retired it: nothing installs, settles or re-records it.
    Retired,
    /// Its copy and completed record match the declaration.
    Current {
        package: DeclaredPackage,
        source_hash: String,
        rendered_hash: String,
    },
    /// `update-pi` installs it.
    Install {
        package: DeclaredPackage,
        change: Install,
    },
    /// Pi already loads `installed`, this package under this name or an
    /// earlier one, from `at`, a root it loads with this one: an install
    /// here would register it twice, and Pi will not start like that.
    LoadedElsewhere { installed: String, at: PathBuf },
    /// The record names another source than the declaration
    /// (`check_origin`): no install replaces bytes another source wrote.
    OriginRefused(CoreError),
    /// Its source would not resolve, or its copy or record would not
    /// compare: nothing was judged.
    NotEvaluated(CoreError),
}

impl Admission {
    /// Why `update-pi` leaves the package, and the reason a report draws
    /// for it; `None` where it installs the package or nothing is owed.
    pub fn unsettled(&self) -> Option<(crate::engine::PiUnsettled, String)> {
        use crate::engine::PiUnsettled;
        match self {
            Admission::Retired | Admission::Current { .. } | Admission::Install { .. } => None,
            Admission::LoadedElsewhere { installed, at } => Some((
                PiUnsettled::LoadedElsewhere,
                format!(
                    "carrier package does not match, and {installed} is installed at {} as well; Pi loads both package lists together and will not start with one package registered twice, so update-pi leaves it until one copy is removed",
                    at.display()
                ),
            )),
            Admission::OriginRefused(error) => {
                Some((PiUnsettled::OriginRefused, uncompared(error)))
            }
            Admission::NotEvaluated(error) => Some((PiUnsettled::NotEvaluated, uncompared(error))),
        }
    }
}

/// What an admitted install changes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Install {
    /// Nothing is installed at the declared name yet.
    Missing,
    /// The installed copy or its completed record differs.
    Stale,
}

/// Admit one declared package against `existing`, its record, as `basis`
/// asks: the resolution, the origin, the installed bytes, and the install
/// guard over `other_roots`, the roots Pi loads with `root`
/// (`paired_roots`). A copy that is current needs no guard: nothing
/// installs it again.
pub fn admit(
    root: &Path,
    other_roots: &[PathBuf],
    name: &str,
    resolved: Result<Resolved>,
    existing: Option<&crate::lock::LockEntry>,
    basis: RecordBasis,
) -> Admission {
    let package = match resolved {
        Ok(Resolved::Ships(package)) => package,
        Ok(Resolved::Retired { .. }) => return Admission::Retired,
        Err(error) => return Admission::NotEvaluated(error),
    };
    if let Err(error) = check_origin(name, &package, existing) {
        return Admission::OriginRefused(error);
    }
    let change = match declared_state(root, name, &package, existing, basis) {
        Ok(PackageState::Current {
            source_hash,
            rendered_hash,
        }) => {
            return Admission::Current {
                package,
                source_hash,
                rendered_hash,
            };
        }
        Ok(PackageState::Missing) => Install::Missing,
        Ok(PackageState::Different) => Install::Stale,
        Err(error) => return Admission::NotEvaluated(error),
    };
    match super::duplicate_elsewhere(name, other_roots) {
        Some((installed, at)) => Admission::LoadedElsewhere { installed, at },
        None => Admission::Install { package, change },
    }
}

/// Build a durable record only when the installed copy matches the declared
/// source byte for byte or under the destination path's Git text policy.
/// Any other difference is not ownership evidence. The entry's enabled flag
/// records the native extension filter, not an assumed installation default.
pub fn matching_lock_entry(
    scope_root: &Path,
    name: &str,
    package: &DeclaredPackage,
    existing: Option<&crate::lock::LockEntry>,
    basis: RecordBasis,
) -> Result<Option<crate::lock::LockEntry>> {
    // No other root: whether an install would be guarded is not this
    // question, only whether the copy is the declaration's.
    match admit(
        scope_root,
        &[],
        name,
        Ok(Resolved::Ships(package.clone())),
        existing,
        basis,
    ) {
        Admission::Current {
            package,
            source_hash,
            rendered_hash,
        } => lock_entry(
            scope_root,
            name,
            &package,
            existing,
            source_hash,
            rendered_hash,
        )
        .map(Some),
        Admission::Install { .. } => Ok(None),
        Admission::OriginRefused(error) | Admission::NotEvaluated(error) => Err(error),
        Admission::Retired | Admission::LoadedElsewhere { .. } => {
            unreachable!("a shipped package admitted against no other root")
        }
    }
}

/// The record of a copy `admit` found current.
fn lock_entry(
    scope_root: &Path,
    name: &str,
    package: &DeclaredPackage,
    existing: Option<&crate::lock::LockEntry>,
    source_hash: String,
    rendered_hash: String,
) -> Result<crate::lock::LockEntry> {
    let installed_at = existing
        .filter(|entry| super::state::matches_record(entry, name, &source_hash, &rendered_hash))
        .and_then(|entry| entry.machine.as_ref())
        .map_or_else(crate::clock::timestamp, |machine| {
            machine.installed_at.clone()
        });
    Ok(crate::lock::LockEntry {
        name: name.to_owned(),
        kind: crate::model::ItemKind::PiExtension,
        harness: crate::model::HarnessId::Pi,
        source: package.source.clone(),
        source_repo: package.source_repo.clone(),
        machine: Some(crate::lock::MachineRecord {
            method: crate::manifest::Method::Copy,
            installed_at,
        }),
        source_hash,
        source_commit: package.source_commit.clone(),
        selector: package.selector.clone(),
        rendered_hash: Some(rendered_hash),
        enabled: super::settings::package_enabled(&super::settings_path(scope_root), name)?
            .ok_or_else(|| CoreError::PiPackage {
                name: name.to_owned(),
                message: "matching package lost its settings registration".to_owned(),
            })?,
        upstream_skills: None,
        emitted: None,
        registration: None,
        output_style: None,
        reasons: std::collections::BTreeSet::from([crate::lock::Reason::Requested]),
    })
}

/// Where a planning pass collects what a declaration's switch changes: the
/// native switches' settings write, and each `APPEND_SYSTEM.md` edit a
/// package's block needs with its label, which the plan composes with the
/// file's other edits into one mutation.
pub struct SwitchPlan<'a> {
    pub ops: &'a mut Vec<crate::apply::PlannedOp>,
    pub edits: &'a mut Vec<(PathBuf, String, crate::configedit::ConfigEdit)>,
}

/// Compare each declared carrier package and preserve durable provenance.
/// Missing or unreadable bytes produce drift rather than an omitted row,
/// except an `APPEND_SYSTEM.md` a plan cannot compare, which fails it.
/// A package's `APPEND_SYSTEM.md` block follows its declaration, not the
/// native filter: a disable Pi already set needs no switch, yet the
/// declaration still takes the block away. With `plan`, plan native
/// switches and block edits and record their intended state. Without it,
/// retain the observed switch for read-only recovery and installation.
pub fn record_matching_manifest(
    env: &Env,
    scope: &crate::model::Scope,
    manifest: &crate::manifest::Manifest,
    lock: &mut crate::lock::Lock,
    selectors: Option<&std::collections::BTreeMap<String, Option<crate::lock::DeclaredSelector>>>,
    basis: RecordBasis,
    plan: Option<SwitchPlan<'_>>,
) -> Result<Vec<crate::engine::DriftRow>> {
    record_matching(
        env,
        scope,
        manifest,
        lock,
        manifest.pi_extensions.iter(),
        selectors,
        basis,
        plan,
    )
}

/// Compare one declaration after its carrier install completed.
pub fn record_matching_name(
    env: &Env,
    scope: &crate::model::Scope,
    manifest: &crate::manifest::Manifest,
    lock: &mut crate::lock::Lock,
    selectors: Option<&std::collections::BTreeMap<String, Option<crate::lock::DeclaredSelector>>>,
    name: &str,
) -> Result<Vec<crate::engine::DriftRow>> {
    record_matching(
        env,
        scope,
        manifest,
        lock,
        manifest.pi_extensions.get_key_value(name).into_iter(),
        selectors,
        RecordBasis::MatchedBytes,
        None,
    )
}

#[allow(clippy::too_many_arguments)]
fn record_matching<'a>(
    env: &Env,
    scope: &crate::model::Scope,
    manifest: &crate::manifest::Manifest,
    lock: &mut crate::lock::Lock,
    declarations: impl Iterator<Item = (&'a String, &'a crate::manifest::ItemDecl)>,
    selectors: Option<&std::collections::BTreeMap<String, Option<crate::lock::DeclaredSelector>>>,
    basis: RecordBasis,
    mut plan: Option<SwitchPlan<'_>>,
) -> Result<Vec<crate::engine::DriftRow>> {
    use crate::engine::{DriftRow, DriftState, RowRemedy};
    use crate::model::{HarnessId, ItemKind};
    // The roots `update-pi` checks when it is run on this scope alone, as
    // the finish naming it runs it.
    let settings = crate::settings::load(env)?;
    let (root, other_roots) = paired_roots(env, &settings, scope, std::slice::from_ref(scope));
    let mut drift = Vec::new();
    let mut switches = Vec::new();
    for (name, decl) in declarations {
        let key = crate::lock::entry_key(ItemKind::PiExtension, name, HarnessId::Pi);
        let resolved = resolve_declared(env, scope, manifest, name, decl).map(|resolved| {
            match (resolved, selectors) {
                (Resolved::Ships(mut package), Some(selectors)) => {
                    package.selector = selectors.get(name).cloned().unwrap_or_else(|| {
                        unreachable!("a planned Pi reading has its selector basis")
                    });
                    Resolved::Ships(package)
                }
                (resolved, _) => resolved,
            }
        });
        let existing = lock.entries.get(&key);
        let mut remedy = None;
        let admission = admit(&root, &other_roots, name, resolved, existing, basis);
        let (mut unsettled, left) = admission.unsettled().unzip();
        let (detail, cause) = match admission {
            Admission::Retired => continue,
            Admission::Current {
                package,
                source_hash,
                rendered_hash,
            } => {
                let entry = lock_entry(&root, name, &package, existing, source_hash, rendered_hash);
                let switched = (key, entry);
                match planned_switch(
                    env,
                    &root,
                    (name, decl),
                    switched,
                    lock,
                    &mut plan,
                    &mut switches,
                )? {
                    Some((detail, cause, held)) => {
                        unsettled = held;
                        (detail, cause)
                    }
                    None => continue,
                }
            }
            Admission::Install { .. } => {
                remedy = Some(RowRemedy::UpdatePi);
                (
                    "carrier package or completed install record does not match; update-pi must settle it"
                        .to_owned(),
                    None,
                )
            }
            Admission::LoadedElsewhere { .. }
            | Admission::OriginRefused(_)
            | Admission::NotEvaluated(_) => (
                left.unwrap_or_else(|| unreachable!("an unsettled admission has its reason")),
                None,
            ),
        };
        drift.push(DriftRow {
            kind: ItemKind::PiExtension,
            name: name.clone(),
            harness: HarnessId::Pi,
            scope: scope.clone(),
            state: DriftState::Stale,
            detail,
            cause,
            compared: None,
            also_in_the_way: Vec::new(),
            remedy,
            pi_unsettled: unsettled,
        });
    }
    if let Some(plan) = plan
        && !switches.is_empty()
    {
        plan.ops.push(switches_write(&root, switches)?);
    }
    Ok(drift)
}

/// The one settings write that sets every native switch a plan changes.
fn switches_write(root: &Path, switches: Vec<(&str, bool)>) -> Result<crate::apply::PlannedOp> {
    let path = super::settings_path(root);
    let pre = crate::apply::Pre::observed(&path)?;
    let text = super::settings::toggled_packages(&path, switches.into_iter())?;
    Ok(crate::apply::PlannedOp {
        description: "Set Pi package extension filters".into(),
        op: crate::apply::Op::WriteFile {
            path,
            bytes: text.into_bytes(),
            pre,
        },
    })
}

/// A row's detail, cause and unsettled reason.
type SwitchRow = (
    String,
    Option<crate::engine::DriftCause>,
    Option<crate::engine::PiUnsettled>,
);

fn uncompared(error: &CoreError) -> String {
    format!("carrier package could not be compared: {error}")
}

/// Record a current package's entry, and with `plan` plan the native
/// switch and the `APPEND_SYSTEM.md` block its declaration changes. The
/// row it leaves, where it leaves one: one a plan writes carries
/// `UpstreamChanged`, the cause a plan simply writes; a read-only pass
/// writes neither, so its row carries no cause it would borrow from a
/// write nobody runs.
fn planned_switch<'a>(
    env: &Env,
    root: &Path,
    (name, decl): (&'a String, &crate::manifest::ItemDecl),
    (key, entry): (String, Result<crate::lock::LockEntry>),
    lock: &mut crate::lock::Lock,
    plan: &mut Option<SwitchPlan<'_>>,
    switches: &mut Vec<(&'a str, bool)>,
) -> Result<Option<SwitchRow>> {
    let mut entry = match entry {
        Ok(entry) => entry,
        Err(error) => {
            return Ok(Some((
                uncompared(&error),
                None,
                Some(crate::engine::PiUnsettled::NotEvaluated),
            )));
        }
    };
    let differs = entry.enabled != decl.enabled;
    // A plan fails on a block it cannot compare, as a toggle must before
    // it saves the manifest: a switch never lands without its block. Only
    // the read-only pass reports it.
    let block = match block_edit(env, root, name, decl.enabled) {
        Err(error) if plan.is_some() => return Err(error),
        block => block,
    };
    if let Some(plan) = plan.as_mut()
        && let Ok(edit) = &block
    {
        if differs {
            switches.push((name.as_str(), decl.enabled));
            entry.enabled = decl.enabled;
        }
        if let Some((path, edit)) = edit {
            plan.edits
                .push((path.clone(), format!("{name} instructions"), edit.clone()));
        }
    }
    let written = plan
        .is_some()
        .then_some(crate::engine::DriftCause::UpstreamChanged);
    lock.entries.insert(key, entry);
    Ok(match block {
        Err(error) => Some((
            format!("APPEND_SYSTEM.md block could not be compared: {error}"),
            None,
            None,
        )),
        Ok(_) if differs => Some((
            "native extension filter does not match the enabled declaration".to_owned(),
            written,
            None,
        )),
        Ok(Some(_)) => Some((
            "APPEND_SYSTEM.md block does not match the package's enabled state (declaration or kendex.extensionManager.config)".to_owned(),
            written,
            None,
        )),
        Ok(None) => None,
    })
}

/// The edit that brings the package's `APPEND_SYSTEM.md` block in line with
/// a declaration's `enabled`, or `None` where the file already holds what
/// the declaration wants, wherever the block sits in it.
fn block_edit(
    env: &Env,
    root: &Path,
    name: &str,
    enabled: bool,
) -> Result<Option<(PathBuf, crate::configedit::ConfigEdit)>> {
    let (path, edit) = super::append_system_edit(env, root, name, enabled)?;
    let current = crate::fs::read_if_exists(&path)?.unwrap_or_default();
    let in_sync = edit
        .in_sync(&current)
        .map_err(|message| CoreError::ConfigEdit {
            path: path.clone(),
            message,
        })?;
    Ok((!in_sync).then_some((path, edit)))
}

/// Refuse a toggle that the carrier comparison cannot plan. A manifest-only
/// toggle must not claim it changed what Pi loads.
pub(crate) fn ensure_toggle_ready(
    env: &Env,
    scope: &crate::model::Scope,
    manifest: &crate::manifest::Manifest,
    lock: &crate::lock::Lock,
    name: &str,
) -> Result<()> {
    let decl = &manifest.pi_extensions[name];
    let root = scope_root(env, scope)?;
    let package = match resolve_declared(env, scope, manifest, name, decl)? {
        Resolved::Ships(package) => package,
        Resolved::Retired { .. } => {
            return Err(CoreError::PiPackage {
                name: name.to_owned(),
                message: "its catalog retired it, so it stays as it is until it is removed"
                    .to_owned(),
            });
        }
    };
    let key = crate::lock::entry_key(
        crate::model::ItemKind::PiExtension,
        name,
        crate::model::HarnessId::Pi,
    );
    if matching_lock_entry(
        &root,
        name,
        &package,
        lock.entries.get(&key),
        RecordBasis::Recorded,
    )?
    .is_none()
    {
        return Err(CoreError::PiPackage {
            name: name.to_owned(),
            message: "carrier package or completed install record does not match; update-pi before toggling".to_owned(),
        });
    }
    Ok(())
}

/// Refuse a source rebind before the carrier changes any installed bytes.
pub fn check_origin(
    name: &str,
    package: &DeclaredPackage,
    existing: Option<&crate::lock::LockEntry>,
) -> Result<()> {
    if let Some(existing) = existing
        && crate::source_ref::repo_identity(&existing.source_repo)
            != crate::source_ref::repo_identity(&package.source_repo)
    {
        return Err(CoreError::PiPackage {
            name: name.to_owned(),
            message: format!(
                "recorded source {} conflicts with declared source {}",
                existing.source_repo, package.source_repo
            ),
        });
    }
    Ok(())
}

/// Where a scope's packages install.
pub fn scope_root(env: &Env, scope: &crate::model::Scope) -> Result<PathBuf> {
    let settings = crate::settings::load(env)?;
    Ok(match scope {
        crate::model::Scope::Global => global_root(env, &settings),
        crate::model::Scope::Project { root } => root.join(".pi"),
    })
}

/// Where a scope's packages install, and every root an install there
/// must be checked against before writing: Pi loads the global root and
/// a project's together, and which project comes later, so a guard that
/// refuses a package registered twice looks at every project this
/// machine knows, the registered ones, the one the command runs in, and
/// each project in `targeted`, the scopes the command writes. A project
/// a command names is registered only after its write, or never (a
/// declined write, a linked work tree, a temporary folder), and a
/// personal copy of a package it already holds would load twice there.
/// For a project that is the global root alone.
pub fn paired_roots(
    env: &Env,
    settings: &crate::settings::AppSettings,
    scope: &crate::model::Scope,
    targeted: &[crate::model::Scope],
) -> (PathBuf, Vec<PathBuf>) {
    let global = global_root(env, settings);
    match scope {
        crate::model::Scope::Global => {
            let mut projects = settings.projects.clone();
            let reached = crate::discover::current_project(env).into_iter().chain(
                targeted.iter().filter_map(|scope| match scope {
                    crate::model::Scope::Project { root } => Some(root.clone()),
                    crate::model::Scope::Global => None,
                }),
            );
            for project in reached {
                if !projects.contains(&project) {
                    projects.push(project);
                }
            }
            (
                global,
                projects.iter().map(|project| project.join(".pi")).collect(),
            )
        }
        crate::model::Scope::Project { root } => (root.join(".pi"), vec![global]),
    }
}

/// Where a scope's packages install, and the one other root Pi loads
/// beside it in the session a command runs in: the global root and the
/// current project's `.pi`, registered or not, and nothing else. A report
/// of what Pi loads twice reads these; the install guard reads
/// [`paired_roots`].
pub fn session_roots(
    env: &Env,
    settings: &crate::settings::AppSettings,
    scope: &crate::model::Scope,
) -> (PathBuf, Vec<PathBuf>) {
    let global = global_root(env, settings);
    match scope {
        crate::model::Scope::Global => (
            global,
            crate::discover::current_project(env)
                .map(|here| here.join(".pi"))
                .into_iter()
                .collect(),
        ),
        crate::model::Scope::Project { root } => (root.join(".pi"), vec![global]),
    }
}

fn global_root(env: &Env, settings: &crate::settings::AppSettings) -> PathBuf {
    use crate::harness::HarnessAdapter;
    let pi = crate::harness::pi::Pi;
    settings
        .harness_roots
        .get(pi.id().name())
        .cloned()
        .unwrap_or_else(|| pi.default_global_root(env))
}
