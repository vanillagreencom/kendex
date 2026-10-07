//! The per-scope drift snapshot: everything the session-start check needs,
//! derived once wherever the deep work already runs — `updates`, `refresh`,
//! `apply`, and the detached background fetch — and read cheaply forever
//! after. Derived, machine-local, rebuildable: losing one costs a
//! re-derivation, never intent.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::env::Env;
use crate::error::Result;
use crate::fs::{atomic_write, read_if_exists};
use crate::model::{ItemKind, Scope};

/// Bumped when the shape changes; an older or newer snapshot reads as
/// absent, which the check reports as not-yet-evaluated.
pub const SNAPSHOT_SCHEMA: u32 = 4;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub struct ScopeSnapshot {
    pub schema: u32,
    /// Unix seconds when this was derived — what the check renders as age.
    pub taken_at: u64,
    /// The scope's label, for a human reading the file.
    pub scope: String,
    pub packages: Vec<PackageSnapshot>,
    /// Evidence the derivation could not read — a mirror whose history
    /// failed, a source that refused. The check reports these as
    /// could-not-check lines while their mirror state still matches.
    pub unreadable: Vec<UnreadableSnapshot>,
}

/// A failed evaluation belongs to the mirror state that produced it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub struct UnreadableSnapshot {
    pub kind: ItemKind,
    pub name: String,
    pub message: String,
    /// The warning's technical cause, for `check --verbose` and `--json`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    pub repo: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refs_state: Option<String>,
}

impl ScopeSnapshot {
    pub(crate) fn sources_changed(&self, env: &Env) -> bool {
        self.packages
            .iter()
            .any(|package| source_changed(env, &package.repo, package.refs_state.as_deref()))
            || self
                .unreadable
                .iter()
                .any(|note| source_changed(env, &note.repo, note.refs_state.as_deref()))
    }
}

pub(crate) fn source_changed(env: &Env, repo: &str, evaluated: Option<&str>) -> bool {
    if repo.is_empty() {
        return false;
    }
    let key = crate::remote::cache_key(env, repo);
    super::stamps::load(env, &key).refs_state.as_deref() != evaluated
}

/// One package's standing at derivation time.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub struct PackageSnapshot {
    pub kind: ItemKind,
    pub name: String,
    pub source: String,
    pub repo: String,
    /// The mirror's refs digest when this verdict was computed. The check
    /// compares it against the fetch stamp: a mirror that moved since makes
    /// the verdict a guess, and the package reads as unevaluated.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refs_state: Option<String>,
    pub update_available: bool,
    pub removed_upstream: bool,
    /// Held by the effective graph — its own pin, a pinned source, bundle,
    /// or dependency parent. Held is clean: the report says nothing.
    pub held: bool,
    pub ignored: bool,
    pub edited: bool,
    pub mixed: bool,
    pub forked: bool,
}

pub fn snapshot_path(env: &Env, scope: &Scope) -> PathBuf {
    let label = scope.canonical().label();
    let digest = &crate::hash::hash_bytes(label.as_bytes())[..16];
    env.drift_dir().join(format!("{digest}.json"))
}

/// What the snapshot file holds. A missing, corrupt, or other-schema file
/// is absent: the next deep pass rewrites it, and until then the scope is
/// not yet evaluated. A file that exists and cannot be read is a different
/// thing — no deep pass fixes a permission or a directory in the way — so
/// it carries its error for the check to report as could-not-check.
#[derive(Debug)]
pub enum SnapshotFile {
    Absent,
    Unreadable(String),
    Current(ScopeSnapshot),
}

pub fn load(env: &Env, scope: &Scope) -> SnapshotFile {
    let text = match read_if_exists(&snapshot_path(env, scope)) {
        Ok(Some(text)) => text,
        Ok(None) => return SnapshotFile::Absent,
        Err(error) => return SnapshotFile::Unreadable(error.to_string()),
    };
    match serde_json::from_str::<ScopeSnapshot>(&text) {
        Ok(snapshot) if snapshot.schema == SNAPSHOT_SCHEMA => SnapshotFile::Current(snapshot),
        Ok(_) | Err(_) => SnapshotFile::Absent,
    }
}

pub fn store(env: &Env, scope: &Scope, snapshot: &ScopeSnapshot) -> Result<()> {
    let mut text = serde_json::to_string_pretty(snapshot).unwrap_or_default();
    text.push('\n');
    atomic_write(&snapshot_path(env, scope), &text)
}

/// Drop the scope's snapshot: the state it described just changed. The
/// check then reports "not yet evaluated" — the honest maybe — until the
/// next deep pass re-derives it.
pub fn invalidate(env: &Env, scope: &Scope) -> Result<()> {
    match std::fs::remove_file(snapshot_path(env, scope)) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(crate::error::CoreError::io(
            snapshot_path(env, scope),
            error,
        )),
    }
}

/// Derive the scope's snapshot from the deep reads and store it. This is
/// the expensive path — mirrors, plans, scoring — and it belongs exactly
/// where callers are already paying for that work.
pub fn record(env: &Env, scope: &Scope) -> Result<ScopeSnapshot> {
    let report = crate::package::updates::updates(env, scope)?;
    record_with(env, scope, &report)
}

/// [`record`] for a caller that already computed the update standings —
/// the app's overview query, which must not pay the mirror walk twice.
pub fn record_with(
    env: &Env,
    scope: &Scope,
    report: &crate::package::updates::UpdatesReport,
) -> Result<ScopeSnapshot> {
    let mut refs_by_repo: std::collections::BTreeMap<String, Option<String>> = Default::default();
    let mut packages = Vec::new();
    for row in &report.rows {
        let refs_state = evaluated_refs(env, &row.repo, &mut refs_by_repo);
        packages.push(PackageSnapshot {
            kind: row.kind,
            name: row.name.clone(),
            source: row.source.clone(),
            repo: row.repo.clone(),
            refs_state,
            update_available: row.update_available,
            removed_upstream: row.removed_upstream,
            held: row.pinned,
            ignored: row.ignored,
            edited: row.blocked_by_local_edit,
            mixed: row.mixed,
            forked: row.forked,
        });
    }
    let mut repos: std::collections::BTreeMap<_, _> = report
        .rows
        .iter()
        .map(|row| ((row.kind, row.name.clone()), row.repo.clone()))
        .collect();
    // A source that could not resolve produces a warning without a row.
    // The effective declarations also cover bundle members and dependencies.
    if report
        .warnings
        .iter()
        .any(|warning| !repos.contains_key(&(warning.kind, warning.name.clone())))
        && let Some(manifest) =
            crate::manifest::load_current(&crate::manifest::manifest_path(env, scope))?
    {
        for planned in crate::engine::planned_declarations(env, scope, &manifest) {
            let repo = manifest
                .sources
                .get(&planned.decl.source)
                .and_then(|source| source.repo.clone())
                .unwrap_or_default();
            repos.entry((planned.kind, planned.name)).or_insert(repo);
        }
    }
    let unreadable = report
        .warnings
        .iter()
        .map(|warning| {
            let repo = repos
                .get(&(warning.kind, warning.name.clone()))
                .cloned()
                .unwrap_or_default();
            UnreadableSnapshot {
                kind: warning.kind,
                name: warning.name.clone(),
                message: warning.message.clone(),
                detail: warning.detail.clone(),
                refs_state: evaluated_refs(env, &repo, &mut refs_by_repo),
                repo,
            }
        })
        .collect();
    let snapshot = ScopeSnapshot {
        schema: SNAPSHOT_SCHEMA,
        taken_at: crate::clock::unix_now(),
        scope: scope.canonical().label(),
        packages,
        unreadable,
    };
    store(env, scope, &snapshot)?;
    Ok(snapshot)
}

fn evaluated_refs(
    env: &Env,
    repo: &str,
    refs_by_repo: &mut std::collections::BTreeMap<String, Option<String>>,
) -> Option<String> {
    if repo.is_empty() {
        return None;
    }
    refs_by_repo
        .entry(repo.to_owned())
        .or_insert_with(|| {
            let key = crate::remote::cache_key(env, repo);
            super::stamps::refs_state(&crate::remote::store::mirror_dir(env, &key))
        })
        .clone()
}
