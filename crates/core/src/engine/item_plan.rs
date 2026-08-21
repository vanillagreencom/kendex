use std::collections::BTreeSet;
use std::path::PathBuf;

use super::{DriftRow, DriftState};
use crate::apply::{Op, PlannedOp, Pre};
use crate::clock::timestamp;
use crate::env::Env;
use crate::error::Result;
use crate::hash::hash_tree;
use crate::lock::{Lock, LockEntry};
use crate::model::Scope;

use super::config_edits::ConfigEditPlan;
use super::desired::{Artifact, Desired};
use super::tree_plan::{Written, plan_tree};

/// Everything one pass over the desired items accumulates.
pub(super) struct PlanSink<'a> {
    pub(super) drift: &'a mut Vec<DriftRow>,
    pub(super) ops: &'a mut Vec<PlannedOp>,
    pub(super) config_edits: &'a mut ConfigEditPlan,
    pub(super) new_lock: &'a mut Lock,
    pub(super) written: &'a mut Written,
}

/// `owned` holds every path an earlier install wrote under another kind's
/// name: a codex command lands as a skill tree, and the skill that later
/// claims that name is replacing our own output, not adopting a stranger's.
pub(super) fn plan_item(
    env: &Env,
    item: &Desired,
    scope: &Scope,
    lock: &Lock,
    owned: &BTreeSet<PathBuf>,
    sink: &mut PlanSink,
) -> Result<()> {
    let PlanSink {
        drift,
        ops,
        config_edits,
        new_lock,
        written,
    } = sink;
    let row = |state: DriftState, detail: String| DriftRow {
        kind: item.kind,
        name: item.name.clone(),
        harness: item.harness,
        scope: scope.clone(),
        state,
        detail,
        cause: None,
    };
    let existing = lock.entries.get(&item.key);

    // Invariant 4: a recorded source is never silently rebound. The one
    // sanctioned rebind is a recorded fork — remote to local, written into
    // the manifest by the fork operation the user confirmed.
    if let Some(entry) = existing
        && entry.source_repo != item.provenance
        && entry.source_repo != "local"
        && !(item.provenance == crate::manifest::LOCAL_SOURCE_NAME && item.recorded_fork)
    {
        drift.push(row(
            DriftState::Conflict,
            format!(
                "installed from {} but now set to come from {} — remove it first",
                entry.source_repo, item.provenance
            ),
        ));
        new_lock.entries.insert(item.key.clone(), entry.clone());
        return Ok(());
    }

    let planned = match &item.artifact {
        Artifact::File { .. } => plan_file(env, scope, item, existing.is_some(), ops),
        Artifact::Tree { .. } => plan_tree(env, item, existing.is_some(), owned, written, ops),
        Artifact::Registration { .. } => {
            plan_registration(env, scope, item, existing.is_some(), ops, config_edits)
        }
    }?;
    let dirty = !matches!(planned, Planned::Clean);
    match planned {
        Planned::Conflict(detail) => {
            drift.push(row(DriftState::Conflict, detail));
            if let Some(entry) = existing {
                new_lock.entries.insert(item.key.clone(), entry.clone());
            }
            return Ok(());
        }
        Planned::Drift(state, detail) => drift.push(row(state, detail)),
        Planned::Clean => {}
    }

    let hash_moved = existing.is_some_and(|entry| entry.source_hash != item.hash);
    if hash_moved && !dirty {
        drift.push(row(
            DriftState::Stale,
            "source or customization changed since install".into(),
        ));
    }
    let installed_at = match existing {
        Some(entry) if !dirty && !hash_moved => entry.installed_at.clone(),
        _ => timestamp(),
    };
    new_lock.entries.insert(
        item.key.clone(),
        LockEntry {
            name: item.name.clone(),
            kind: item.kind,
            harness: item.harness,
            source: item.source_name.clone(),
            source_repo: item.provenance.clone(),
            method: item.method,
            installed_at,
            source_hash: item.hash.clone(),
            source_commit: item.source_commit.clone(),
            rendered_hash: rendered_hash(&item.artifact),
            enabled: item.enabled,
            upstream_skills: item.upstream_skills.clone(),
            emitted: item.emitted.clone(),
            registration: super::desired_custom_hooks::hook_registration(item),
            reasons: item.reasons.clone(),
            author_review: super::review_hash::author_review(item),
        },
    );
    Ok(())
}

/// What this artifact leaves on disk, for edit detection later. Only file
/// and tree artifacts have a meaningful disk identity; a registration's
/// shared config file holds other people's keys, so hashing it would read
/// every unrelated settings change as an edit of ours.
fn rendered_hash(artifact: &Artifact) -> Option<String> {
    match artifact {
        Artifact::File { .. } | Artifact::Tree { .. } => {
            Some(super::desired::artifact_disk_hash(artifact))
        }
        // A hook's backing script is a file kendex alone writes, so it can
        // be anchored like any other. A registration with no script edits
        // only shared config, which holds other people's keys — nothing to
        // anchor there.
        Artifact::Registration {
            script: Some(_), ..
        } => Some(super::desired::artifact_disk_hash(artifact)),
        Artifact::Registration { script: None, .. } => None,
    }
}

/// A hook the tool only reads is named as such wherever the plan is shown.
/// An op that reads like protection must not hide that this tool is free to
/// ignore what it installs. Read through `hook_enforcement`, so a Pi hook
/// with no carrier registered anywhere is labeled advisory, not enforced.
fn advisory(env: &Env, scope: &Scope, item: &Desired) -> &'static str {
    use crate::harness::Enforcement;
    if item.kind != crate::model::ItemKind::Hook {
        return "";
    }
    match crate::harness::hook_enforcement(env, scope, item.harness) {
        Enforcement::Advisory => " (advisory)",
        Enforcement::Enforced | Enforcement::NotApplicable => "",
    }
}

#[derive(Debug, Clone, PartialEq)]
pub(super) enum Planned {
    Clean,
    Drift(DriftState, String),
    Conflict(String),
}

fn plan_file(
    env: &Env,
    scope: &Scope,
    item: &Desired,
    locked: bool,
    ops: &mut Vec<PlannedOp>,
) -> Result<Planned> {
    let Artifact::File { path, bytes } = &item.artifact else {
        return Ok(Planned::Clean);
    };
    plan_written_file(env, scope, item, path, bytes, locked, ops)
}

#[allow(clippy::too_many_arguments)]
fn plan_written_file(
    env: &Env,
    scope: &Scope,
    item: &Desired,
    path: &std::path::Path,
    bytes: &[u8],
    locked: bool,
    ops: &mut Vec<PlannedOp>,
) -> Result<Planned> {
    if path.is_symlink() {
        return Ok(Planned::Conflict(format!(
            "{} is a link kendex did not create",
            path.display()
        )));
    }
    if path.exists() && !path.is_file() {
        return Ok(Planned::Conflict(format!(
            "a directory sits at {}",
            path.display()
        )));
    }
    // An artifact we cannot hash is reported uncompared (invariant 12) —
    // a read error must never read as passing, and must not kill the scope.
    let disk = match path.is_file().then(|| hash_tree(path)).transpose() {
        Ok(disk) => disk,
        Err(error) => {
            return Ok(Planned::Conflict(format!(
                "{} cannot be compared ({error}) — fix its permissions or remove it",
                path.display()
            )));
        }
    };
    let wanted = crate::hash::hash_bytes(bytes);
    match disk {
        Some(current) if current == wanted => Ok(Planned::Clean),
        Some(current) => {
            if !locked {
                return Ok(Planned::Conflict(format!(
                    "{} is not managed yet — start managing it first",
                    path.display()
                )));
            }
            ops.push(PlannedOp {
                description: format!(
                    "Update {} {} for {}{}",
                    item.kind.name(),
                    item.name,
                    item.harness.display_name(),
                    advisory(env, scope, item)
                ),
                op: Op::WriteFile {
                    path: path.to_path_buf(),
                    bytes: bytes.to_vec(),
                    pre: Pre::HashIs { hash: current },
                },
            });
            Ok(Planned::Drift(
                DriftState::Stale,
                "newer content is available".into(),
            ))
        }
        None => Ok(plan_absent_file(env, scope, item, path, bytes, locked, ops)),
    }
}

/// Nothing at the target: our own content may be waiting under the toggled
/// name, otherwise this is a fresh install. Anything else occupying the
/// toggled name belongs to someone else and is never written through.
#[allow(clippy::too_many_arguments)]
fn plan_absent_file(
    env: &Env,
    scope: &Scope,
    item: &Desired,
    path: &std::path::Path,
    bytes: &[u8],
    locked: bool,
    ops: &mut Vec<PlannedOp>,
) -> Planned {
    let alternate = toggle_sibling(path);
    if alternate.is_symlink() {
        return Planned::Conflict(format!(
            "{} is a link kendex did not create",
            alternate.display()
        ));
    }
    if alternate.is_file() {
        if !locked {
            return Planned::Conflict(format!(
                "{} is not managed yet — start managing it first",
                alternate.display()
            ));
        }
        let flip = if item.enabled { "on" } else { "off" };
        ops.push(PlannedOp {
            description: format!("Turn {} {flip}", item.name),
            op: Op::Rename {
                from: alternate,
                to: path.to_path_buf(),
                to_pre: Pre::Absent,
            },
        });
        ops.push(PlannedOp {
            description: format!(
                "Update {} {} for {}{}",
                item.kind.name(),
                item.name,
                item.harness.display_name(),
                advisory(env, scope, item)
            ),
            op: Op::WriteFile {
                path: path.to_path_buf(),
                bytes: bytes.to_vec(),
                pre: Pre::Any,
            },
        });
        return Planned::Drift(DriftState::Stale, format!("should be turned {flip}"));
    }
    ops.push(PlannedOp {
        description: format!(
            "Install {} {} for {}{}",
            item.kind.name(),
            item.name,
            item.harness.display_name(),
            advisory(env, scope, item)
        ),
        op: Op::WriteFile {
            path: path.to_path_buf(),
            bytes: bytes.to_vec(),
            pre: Pre::Absent,
        },
    });
    Planned::Drift(DriftState::Missing, "not installed yet".into())
}

/// A registration is in sync when its backing file matches and re-applying
/// every config edit changes nothing. That idempotency is the whole drift
/// check — unrelated keys in those shared files are never read as ours.
/// Edits that would change the file go to the per-file collector, not
/// straight to ops.
fn plan_registration(
    env: &Env,
    scope: &Scope,
    item: &Desired,
    locked: bool,
    ops: &mut Vec<PlannedOp>,
    config_edits: &mut ConfigEditPlan,
) -> Result<Planned> {
    let Artifact::Registration { script, edits } = &item.artifact else {
        return Ok(Planned::Clean);
    };
    // Every edit is checked before anything is planned: a settings file
    // kendex cannot read back — comments in a JSON, a torn edit — blocks
    // this one registration whole, script included, not the whole scope.
    let mut pending = Vec::new();
    for (path, edit) in edits {
        let current = crate::fs::read_if_exists(path)?.unwrap_or_default();
        match edit.apply(&current) {
            Ok(updated) if updated == current => {}
            Ok(_) => pending.push((path, edit)),
            Err(message) => {
                return Ok(Planned::Conflict(format!(
                    "{} could not be edited: {message}",
                    path.display()
                )));
            }
        }
    }
    let mut planned = match script {
        Some((path, bytes)) => plan_written_file(env, scope, item, path, bytes, locked, ops)?,
        None => Planned::Clean,
    };
    if matches!(planned, Planned::Conflict(_)) {
        return Ok(planned);
    }
    for (path, edit) in pending {
        config_edits.push(
            path.clone(),
            format!("register {}", item.name),
            edit.clone(),
        );
        if matches!(planned, Planned::Clean) {
            planned = match locked {
                true => Planned::Drift(
                    DriftState::Stale,
                    "its settings entry is out of sync".into(),
                ),
                false => Planned::Drift(DriftState::Missing, "not registered yet".into()),
            };
        }
    }
    Ok(planned)
}

/// A declared-disabled artifact keeps its content under the `.disabled`
/// name; toggling is a rename.
fn toggle_sibling(path: &std::path::Path) -> PathBuf {
    let text = path.display().to_string();
    match text.strip_suffix(".disabled") {
        Some(base) => PathBuf::from(base),
        None => PathBuf::from(format!("{text}.disabled")),
    }
}
