//! Everything a scope plan writes that is not one item's own artifact: the
//! shared config files edits land in, the install record, the manifest's
//! format line, and the settings a project's skills seed.

use std::collections::BTreeMap;
use std::path::Path;

use crate::apply::{Op, PlannedOp, Pre};
use crate::base::Base;
use crate::env::Env;
use crate::error::Result;
use crate::lock::{BundleRev, Lock, SourceRev, lock_path};
use crate::manifest::Manifest;
use crate::model::Scope;
use crate::source::SourceState;

use super::config_edits;
use super::desired::DesiredState;
use super::report_types::StoodIn;

/// Whether a plan already persists the manifest. A caller about to insert
/// its own save must know: a second write to the same file binds to bytes
/// the first one replaces and could never run.
pub fn persists_manifest(ops: &[PlannedOp]) -> bool {
    ops.iter()
        .any(|op| matches!(op.op, Op::WriteManifest { .. }))
}

/// The precondition the plan's one manifest write binds to: the base of
/// the editor copy when the manifest arrived whole from one, otherwise
/// the file as it is now. An editor copy's write must bind to the file
/// that copy was read from — observing the path here instead would accept
/// a writer that landed after the copy left the editor.
pub(super) fn manifest_pre(base: Option<&Base>, path: &Path) -> Result<Pre> {
    match base {
        Some(base) => Ok(base.into()),
        None => Pre::observed(path),
    }
}

/// The plan's one manifest write, when anything needs it: skills an agent
/// gained upstream. Nothing else asks for the file — only the current
/// schema loads, so there is no upgrade to plan, and a write planned for
/// its own sake would put a precondition and a plan line in front of the
/// person for a write that lands nothing. One write whatever put it
/// there: a second manifest write could never run, its precondition binds
/// to the bytes the first one replaces.
pub(super) fn plan_manifest_write(
    env: &Env,
    scope: &Scope,
    base: Option<&Base>,
    state: &DesiredState,
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    let Some(update) = &state.manifest_update else {
        return Ok(());
    };
    let path = crate::manifest::manifest_path(env, scope);
    // The schema is not set here: `manifest::save` stamps it, and one
    // place deciding it is the whole point of stamping at the write.
    let written = update.clone();
    ops.push(PlannedOp {
        description: "Add new catalog skills to kendex.toml".into(),
        op: Op::WriteManifest {
            pre: manifest_pre(base, &path)?,
            path,
            manifest: Box::new(written),
        },
    });
    Ok(())
}

/// One mutation per config file, whatever asked for it — a single
/// precondition can hold; per-edit preconditions against the same original
/// bytes cannot.
pub(super) fn plan_config_edits(
    config_edits: config_edits::ConfigEditPlan,
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    for (path, (labels, edits)) in config_edits.by_file {
        // Config edits bind to the bytes reachable at planning. A link
        // already there is kept and its target updated; a same-byte link
        // arriving later also satisfies this precondition.
        let pre = crate::apply::Pre::observed(&path)?;
        let current = crate::fs::read_if_exists(&path)?.unwrap_or_default();
        let remove_empty = crate::configedit::ConfigEdit::removes_empty_document(&edits, &current)
            .map_err(|message| crate::error::CoreError::ConfigEdit {
                path: path.clone(),
                message,
            })?;
        if remove_empty && !path.is_symlink() && path.exists() {
            ops.push(super::removal::trash(
                "Move empty OpenCode settings to the trash".into(),
                path,
            )?);
            continue;
        }
        let file = path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.display().to_string());
        ops.push(PlannedOp {
            description: format!("Update {file} ({})", labels.join(", ")).into(),
            op: Op::EditFile { pre, path, edits },
        });
    }
    Ok(())
}

/// Which commit each installed set was read at, for the lock to record.
/// Carried forward and dropped on the same terms as [`source_revisions`],
/// and read from the same resolutions: a set is read at its declaration's
/// revision, so what it came out as is what that resolution resolved to.
pub(super) fn bundle_revisions(
    manifest: &Manifest,
    lock: &Lock,
    state: &DesiredState,
) -> BTreeMap<String, BundleRev> {
    let mut revisions: BTreeMap<String, BundleRev> = lock
        .bundles
        .iter()
        .filter(|(name, _)| manifest.bundles.contains_key(*name))
        .map(|(name, revision)| (name.clone(), revision.clone()))
        .collect();
    for (name, decl) in &manifest.bundles {
        let resolution = match &decl.rev {
            Some(rev) => state.pinned.get(&(decl.source.clone(), rev.clone())),
            None => state.sources.get(&decl.source),
        };
        let Some(SourceState::Ready(ready)) = resolution else {
            continue;
        };
        let Some(commit) = ready.commit.clone() else {
            continue;
        };
        revisions.insert(
            name.clone(),
            BundleRev {
                source: decl.source.clone(),
                source_repo: ready.provenance.clone(),
                commit,
            },
        );
    }
    revisions
}

/// Which commit each source resolved to, for the lock to record. What
/// earlier passes resolved is carried forward — a source that is offline
/// today should not lose the commit it was reading yesterday — and a source
/// the manifest does not declare drops out. Every declared source is in
/// `state.sources`, whether or not an item names it.
pub(super) fn source_revisions(
    manifest: &Manifest,
    lock: &Lock,
    state: &DesiredState,
) -> BTreeMap<String, SourceRev> {
    let mut revisions: BTreeMap<String, SourceRev> = lock
        .sources
        .iter()
        .filter(|(name, _)| manifest.sources.contains_key(*name))
        .map(|(name, revision)| (name.clone(), revision.clone()))
        .collect();
    for (name, resolution) in &state.sources {
        let (Some(revision), _) = resolved(manifest, name, resolution) else {
            continue;
        };
        revisions.insert(name.clone(), revision);
    }
    revisions
}

/// Each source the planned record carries that this pass cannot hold to
/// a resolution, by name: the ones [`source_revisions`] carried forward
/// unread, and the ones it recorded from the record's own commit. Read
/// from the same resolutions and by the same reading, so a source is
/// never fresh to the record and stood-in to the proof. A source the
/// record does not carry has no entry to hold, so it is never named.
pub(super) fn stood_in_sources(
    manifest: &Manifest,
    planned: &Lock,
    state: &DesiredState,
) -> BTreeMap<String, StoodIn> {
    state
        .sources
        .iter()
        .filter(|(name, _)| planned.sources.contains_key(*name))
        .filter_map(|(name, resolution)| {
            let (_, stood_in) = resolved(manifest, name, resolution);
            stood_in.map(|stood_in| (name.clone(), stood_in))
        })
        .collect()
}

/// The one reading of a source's resolution for the record: the revision
/// to record, when the source resolved to a commit, and why the record
/// cannot be held to it, when it cannot. A path or reserved source has no
/// commit and nothing recorded, so nothing stands in for it; a repository
/// source that is switched off or not fetched leaves its record entry
/// carried forward unread, which is the reading a proof has to refuse.
fn resolved(
    manifest: &Manifest,
    name: &str,
    resolution: &SourceState,
) -> (Option<SourceRev>, Option<StoodIn>) {
    let declares_repository = manifest
        .sources
        .get(name)
        .is_some_and(|decl| decl.repo.is_some());
    match resolution {
        SourceState::Ready(ready) => match ready.commit.clone() {
            Some(commit) => (
                Some(SourceRev {
                    repo: ready.provenance.clone(),
                    rev: manifest.sources.get(name).and_then(|decl| decl.rev.clone()),
                    commit,
                }),
                ready.from_record.then_some(StoodIn::RecordedCommit),
            ),
            None => (None, None),
        },
        SourceState::Pending { .. } => (None, Some(StoodIn::NotFetched)),
        SourceState::Disabled { .. } => (None, declares_repository.then_some(StoodIn::Disabled)),
        SourceState::Missing { .. } => (None, None),
    }
}

/// Which commit each declared revision resolved to this pass, by source
/// name and the revision the declaration pins — `None` for a declaration
/// read at the source's own revision, whose resolution the record
/// carries (earlier passes' included, on [`source_revisions`]' terms),
/// and the pinned revision for one read at a pin of its own. Reported
/// whether or not the plan writes a record: a pass that refuses every
/// install writes none, and a line naming what a refused install was
/// measured against still has to say which commit that was.
pub(super) fn resolved_revisions(
    new_lock: &Lock,
    state: &DesiredState,
) -> BTreeMap<(String, Option<String>), SourceRev> {
    let mut revisions: BTreeMap<(String, Option<String>), SourceRev> = new_lock
        .sources
        .iter()
        .map(|(name, revision)| ((name.clone(), None), revision.clone()))
        .collect();
    for ((name, rev), resolution) in &state.pinned {
        let SourceState::Ready(ready) = resolution else {
            continue;
        };
        let Some(commit) = ready.commit.clone() else {
            continue;
        };
        revisions.insert(
            (name.clone(), Some(rev.clone())),
            SourceRev {
                repo: ready.provenance.clone(),
                rev: Some(rev.clone()),
                commit,
            },
        );
    }
    revisions
}

/// A carrier declaration needs a scope marker while its payload is absent.
fn declares_carrier_installs(manifest: &Manifest) -> bool {
    !manifest.pi_extensions.is_empty()
}

/// Keep a scope marker for carrier declarations even before a payload can be
/// recorded. A scope without declarations or installations needs no lock.
pub(super) fn plan_lock_write(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    new_lock: Lock,
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    let unchanged = new_lock.entries == lock.entries
        && (new_lock.sources == lock.sources || new_lock.entries.is_empty())
        && (new_lock.bundles == lock.bundles || new_lock.entries.is_empty())
        && (lock.version == crate::lock::LOCK_VERSION || lock.entries.is_empty());
    // Whether a file sits at the path is the one question left, and it is
    // asked only where the answer can change what this does: reading it
    // hashes the record, and a scope that has nothing to write and
    // declares nothing the plan leaves unrecorded is done either way.
    if unchanged && !declares_carrier_installs(manifest) {
        return Ok(());
    }
    let path = lock_path(env, scope);
    // The same read the write below binds to. An absent lock and an empty
    // one read alike by this point, and only the file still tells them
    // apart.
    let pre = Pre::observed(&path)?;
    if unchanged && !pre.binds_nothing() {
        return Ok(());
    }
    ops.push(PlannedOp {
        description: "Update the install record".into(),
        op: Op::WriteLock {
            pre,
            path,
            lock: Box::new(new_lock),
        },
    });
    Ok(())
}
