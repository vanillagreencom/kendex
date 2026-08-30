//! Which installed packages have newer versions, computed from the mirrors
//! alone — offline, read-only, no plan. Ignoring a package's updates is a
//! machine-local preference in settings.toml, never manifest intent: a
//! notification choice committed to a shared repository would silence a
//! whole team.

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::engine::ItemWarning;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::remote::history;
use crate::settings;

/// One version a row points at.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct VersionRef {
    pub commit: String,
    /// Release name when a tag points at the commit.
    pub label: Option<String>,
    pub date: Option<String>,
}

/// Whose hold keeps a place at its revision — what the Follow source
/// switch may release, and what it may not.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum HoldOwner {
    /// This declaration's own `rev`: the switch releases it.
    Package,
    /// The source is pinned as a whole; released where the source is declared.
    Source { name: String },
    /// Propagated from the bundle or package that pulled this one in.
    Parent,
}

/// One declared package's update standing.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct UpdateRow {
    pub scope: Scope,
    pub kind: ItemKind,
    pub name: String,
    pub source: String,
    pub repo: String,
    /// `repo` as [`crate::source_ref::repo_identity`] spells it — the one
    /// identity two scopes' rows share when they name one repository two
    /// ways, on any host.
    pub repo_identity: String,
    /// The content revision installed now, when the lock records it.
    pub current: Option<VersionRef>,
    /// The newest content revision the mirror knows.
    pub latest: Option<VersionRef>,
    /// The package's files changed between current and latest — a moved
    /// repository that never touched this package is not an update.
    pub update_available: bool,
    /// Held at a version — the effective installation graph's word, not
    /// only the item's own `rev`: a pinned source, a pinned bundle, or a
    /// pinned dependency parent all hold what they carry.
    pub pinned: bool,
    /// Who holds it, when `pinned`.
    pub hold_owner: Option<HoldOwner>,
    /// The user asked to stop hearing about this package's updates.
    pub ignored: bool,
    /// The installed files were edited by hand; updating is blocked until
    /// the edit is kept as a fork or discarded.
    pub blocked_by_local_edit: bool,
    /// Which renderings carry the edit, one entry per physical rendering:
    /// an agent renders once per tool, while tools sharing a skill's
    /// canonical tree count once. Keeping the edit as a fork captures one
    /// rendering's bytes — it has to be the one that was changed.
    pub edited_harnesses: Vec<HarnessId>,
    /// The edited rendering a fork can capture, when one exists — an
    /// agent edited only in a tool whose format cannot be read back has
    /// none, and the UI must not offer what the engine will refuse.
    pub forkable_harness: Option<HarnessId>,
    /// Whether dropping the edits can put the currently resolved content
    /// back in place, without moving any revision — the source content
    /// resolved, whether or not its history could be read. False once the
    /// source no longer carries the package.
    pub can_discard: bool,
    /// Whether this place can move to the newest content on its own: the
    /// newest is known, and the hold — if any — is this declaration's to
    /// move rather than a bundle's or parent's.
    pub can_take_latest: bool,
    /// Installed as a bundle member or a dependency, with no declaration
    /// of its own: whatever pulled it in owns its revision, and a fork
    /// needs a declaration to turn local.
    pub derived: bool,
    /// This package is a local fork of a catalog item.
    pub forked: bool,
    /// Installations of this package disagree on their source commit.
    pub mixed: bool,
    /// The source's tracked tip no longer carries this package at all.
    pub removed_upstream: bool,
    /// Why this place is never updated one package at a time, when it is
    /// not: the planner derives no plan for the kind, so an Update offered
    /// here could only be refused. `None` for every kind that does plan.
    ///
    /// The refusal travels with the row rather than being worked out again
    /// where it is shown: a surface deciding for itself which kinds are
    /// refused is a second account of a rule that lives in
    /// [`crate::engine::plans_per_package`].
    pub no_per_package_update: Option<String>,
}

/// The refusal a row carries for its kind, when the planner has one.
fn no_per_package_update(kind: ItemKind) -> Option<String> {
    (!crate::engine::plans_per_package(kind))
        .then(|| crate::engine::NO_PER_PACKAGE_UPDATE.to_owned())
}

/// Update standing for one scope, and every package the standing could not
/// be computed for. The warnings are the report's honesty: a package whose
/// mirror cannot be read is listed here, never silently shown as current.
#[derive(Debug, Clone, PartialEq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct UpdatesReport {
    pub rows: Vec<UpdateRow>,
    pub warnings: Vec<ItemWarning>,
    /// When the mirrors behind this standing were last brought current —
    /// Unix seconds, `None` when nothing has ever fetched. A clean report
    /// is only as true as the fetch under it, so the age of that fetch
    /// travels with it rather than being left for the reader to guess.
    ///
    /// `u32` for the same reason [`crate::model::ObservedItem::modified_at`]
    /// is: specta refuses to export a 64-bit int across the IPC boundary.
    pub last_fetched: Option<u32>,
}

/// A package whose update notifications are switched off, by everything
/// that identifies it: an ignore for one project's `gh` skill from one
/// repository must not silence another project's unrelated `gh`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub struct IgnoredUpdate {
    /// `"global"` or the project root path.
    pub scope: String,
    pub kind: ItemKind,
    pub name: String,
    pub repo: String,
}

mod eval;
use eval::Eval;

pub(crate) fn scope_key(scope: &Scope) -> String {
    match scope.canonical() {
        Scope::Global => "global".to_owned(),
        Scope::Project { root } => crate::paths::slashed(&root),
    }
}

/// Every planned remote package's standing — declared items and derived
/// bundle members and dependencies alike — ignored rows included: they come
/// back flagged, never filtered, so the surface that hides them can also
/// offer the way back.
pub fn updates(env: &Env, scope: &Scope) -> Result<UpdatesReport> {
    let Some(manifest) = load_current(env, scope)? else {
        return Ok(UpdatesReport {
            rows: Vec::new(),
            warnings: Vec::new(),
            last_fetched: None,
        });
    };
    let lock = crate::lock::load_file(&crate::lock::lock_path(env, scope))?;
    let lock = match lock {
        crate::lock::LockFile::Current(lock) => lock,
        _ => crate::lock::Lock::default(),
    };
    let eval = Eval {
        env,
        scope,
        ignored: settings::load(env)?.ignored_updates,
        scope_key: scope_key(scope),
        // What the planner will actually hold as an edit — the
        // authoritative signal, so the "edited by you" flag can never
        // disagree with what clicking Update does. One plan for the scope.
        edited: edited_items(env, scope, &manifest, &lock),
        manifest: &manifest,
        lock: &lock,
    };
    let mut report = UpdatesReport {
        rows: Vec::new(),
        warnings: Vec::new(),
        // A stamp that does not fit the narrower type — past 2106, or a
        // clock artifact from the far future — reads as never checked
        // rather than wrapping into a plausible-looking wrong instant.
        last_fetched: crate::remote::last_fetched(env, &manifest)
            .and_then(|at| u32::try_from(at).ok()),
    };
    for planned in crate::engine::planned_declarations(env, scope, &manifest) {
        eval.standing(&planned, &mut report);
    }
    Ok(report)
}

/// The items the planner would hold as hand-edited — read straight from a
/// plan of the scope, so this matches exactly what an update attempt does.
/// A plan that cannot be produced (a broken manifest) blocks nothing here;
/// the audit surfaces that separately.
fn edited_items(
    env: &Env,
    scope: &Scope,
    manifest: &crate::manifest::Manifest,
    lock: &crate::lock::Lock,
) -> std::collections::BTreeMap<(ItemKind, String), Vec<HarnessId>> {
    let mut edited = std::collections::BTreeMap::<(ItemKind, String), Vec<HarnessId>>::new();
    let rows: Vec<(ItemKind, String, HarnessId)> = match crate::engine::plan_scope(
        env,
        scope,
        manifest,
        lock,
        &crate::engine::PlanOptions::default(),
    ) {
        Ok(report) => report
            .drift
            .into_iter()
            .filter(|row| {
                matches!(
                    row.cause,
                    Some(crate::engine::DriftCause::LocalEdit | crate::engine::DriftCause::Both)
                )
            })
            .map(|row| (row.kind, row.name, row.harness))
            .collect(),
        // A plan the scope cannot produce (a broken manifest, an
        // unreadable source) must not fail open — reporting nothing edited
        // is exactly when edit detection could not run. Fall back to the
        // conservative per-entry hold, which holds whatever a record could
        // prove clean and cannot — `edit_holds` names the anchor-less
        // non-pi hook record that can prove nothing and holds nothing.
        Err(_) => lock
            .entries
            .values()
            .filter(|entry| crate::engine::edit_holds(env, scope, entry))
            .map(|entry| (entry.kind, entry.name.clone(), entry.harness))
            .collect(),
    };
    for (kind, name, harness) in rows {
        let harnesses = edited.entry((kind, name.clone())).or_default();
        // One entry per physical rendering: tools that symlink a skill's
        // shared tree report one edit several times, and a fork through
        // any of them captures the same bytes.
        let seen = harnesses.iter().any(|known| {
            *known == harness || same_artifact(env, scope, kind, &name, *known, harness)
        });
        if !seen {
            harnesses.push(harness);
        }
    }
    edited
}

/// Whether two tools read one item from the same files on disk.
fn same_artifact(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    a: HarnessId,
    b: HarnessId,
) -> bool {
    if kind != ItemKind::Skill {
        return false;
    }
    let resolved = |harness| {
        crate::engine::fork::skill_content_path(env, scope, name, harness)
            .map(|path| path.canonicalize().unwrap_or(path))
    };
    matches!((resolved(a), resolved(b)), (Some(x), Some(y)) if x == y)
}

/// A fork's row: no versions, no update — the Library still needs to
/// know it is a fork.
fn fork_row(
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    decl: &crate::manifest::ItemDecl,
) -> UpdateRow {
    UpdateRow {
        scope: scope.clone(),
        kind,
        name: name.to_owned(),
        source: decl.source.clone(),
        repo: String::new(),
        repo_identity: String::new(),
        current: None,
        latest: None,
        update_available: false,
        pinned: false,
        hold_owner: None,
        ignored: false,
        blocked_by_local_edit: false,
        edited_harnesses: Vec::new(),
        forkable_harness: None,
        can_discard: false,
        can_take_latest: false,
        derived: false,
        forked: true,
        mixed: false,
        removed_upstream: false,
        no_per_package_update: no_per_package_update(kind),
    }
}

/// Switch one package's update notifications off or on. A settings write
/// and nothing else: no plan runs, nothing installs, nothing is touched
/// but the preference.
pub fn set_ignored(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    repo: &str,
    ignored: bool,
) -> Result<()> {
    let entry = IgnoredUpdate {
        scope: scope_key(scope),
        kind,
        name: name.to_owned(),
        repo: repo.to_owned(),
    };
    settings::mutate(env, |current| {
        // Replacing or clearing a mute finds it by the four fields it was
        // written with, `repo` exact — an un-mute that missed would leave
        // the old record muting forever.
        current.ignored_updates.retain(|existing| {
            existing.scope != entry.scope
                || existing.kind != entry.kind
                || existing.name != entry.name
                || existing.repo != entry.repo
        });
        if ignored {
            current.ignored_updates.push(entry);
            current.ignored_updates.sort_by(|a, b| {
                (&a.scope, a.kind.name(), &a.name).cmp(&(&b.scope, b.kind.name(), &b.name))
            });
        }
        Ok(())
    })?;
    Ok(())
}

fn load_current(env: &Env, scope: &Scope) -> Result<Option<crate::manifest::Manifest>> {
    match crate::manifest::load(&crate::manifest::manifest_path(env, scope))? {
        crate::manifest::ManifestFile::Current(manifest) => Ok(Some(*manifest)),
        _ => Ok(None),
    }
}
