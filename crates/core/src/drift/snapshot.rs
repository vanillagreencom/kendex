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
pub const SNAPSHOT_SCHEMA: u32 = 1;

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
    /// could-not-check lines, never as silence.
    pub unreadable: Vec<String>,
    /// Installs the safety gate is holding back, scope-wide.
    pub held_back_items: usize,
    /// Open findings awaiting a person, counted once per distinct evidence.
    pub open_evidence: usize,
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
    /// Open findings on this package's installed content.
    pub open_findings: usize,
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
    let scored = crate::engine::observed_rows(env, scope)?;
    let summary = crate::engine::reviewable::review_summary(&scored);
    let open = crate::engine::reviewable::open_by_package(&scored);

    let mut refs_by_repo: std::collections::BTreeMap<String, Option<String>> = Default::default();
    let mut packages = Vec::new();
    for row in &report.rows {
        let refs_state = match row.repo.is_empty() {
            true => None,
            false => refs_by_repo
                .entry(row.repo.clone())
                .or_insert_with(|| {
                    let key = crate::remote::cache_key(env, &row.repo);
                    super::stamps::refs_state(&crate::remote::store::mirror_dir(env, &key))
                })
                .clone(),
        };
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
            open_findings: open
                .get(&(row.kind, row.name.clone()))
                .copied()
                .unwrap_or(0),
        });
    }
    let snapshot = ScopeSnapshot {
        schema: SNAPSHOT_SCHEMA,
        taken_at: crate::clock::unix_now(),
        scope: scope.canonical().label(),
        packages,
        unreadable: report
            .warnings
            .iter()
            .map(|warning| {
                format!(
                    "{} {}: {}",
                    warning.kind.name(),
                    warning.name,
                    warning.message
                )
            })
            .collect(),
        held_back_items: summary.held_back,
        open_evidence: summary.open_evidence,
    };
    store(env, scope, &snapshot)?;
    Ok(snapshot)
}
