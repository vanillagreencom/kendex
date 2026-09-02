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
use crate::model::{ItemKind, Scope};
use crate::source::SourceState;

use super::config_edits;
use super::desired::DesiredState;

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
/// the manifest no longer declares drops out.
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
        let SourceState::Ready(ready) = resolution else {
            continue;
        };
        let Some(commit) = ready.commit.clone() else {
            continue;
        };
        revisions.insert(
            name.clone(),
            SourceRev {
                repo: ready.provenance.clone(),
                rev: manifest.sources.get(name).and_then(|decl| decl.rev.clone()),
                commit,
            },
        );
    }
    revisions
}

/// Whether installs of this kind happen outside the scope plan, so no
/// entry for one can ever land in the record this pass builds.
///
/// Exhaustive on purpose: a kind added to the enum has to be classified
/// here before this compiles, and a kind whose installs move out of the
/// plan is one whose scope would otherwise lose its record.
fn installs_outside_the_plan(kind: ItemKind) -> bool {
    match kind {
        // `kendex update-pi` compares installed bytes against the source
        // and writes the package itself. Nothing about one is derived,
        // planned or recorded here.
        ItemKind::PiExtension => true,
        // A plugin carries no content of its own, but the toggle that
        // turns it on is planned and recorded like any other install.
        ItemKind::Plugin => false,
        ItemKind::Skill
        | ItemKind::Agent
        | ItemKind::Hook
        | ItemKind::Command
        | ItemKind::McpServer => false,
    }
}

/// Whether the scope declares packages no plan can put in the record.
/// Their scope still needs the file: it is what says which build wrote
/// the record, and what verify, edit detection and the sweep key off.
fn declares_unplanned_installs(manifest: &Manifest) -> bool {
    ItemKind::ALL
        .iter()
        .any(|kind| installs_outside_the_plan(*kind) && !manifest.declared(*kind).is_empty())
}

/// An old-version lock rewrites even when its entries are unchanged — the
/// version bump is itself the change. So does a source that now resolves to
/// another commit, once there are installations to reproduce: with nothing
/// installed there is no record to keep, and no lock file is created for
/// one.
///
/// A scope declaring packages the plan never records gets the file back
/// whatever its entries come out as. Nothing about a Pi extension is
/// planned, so a scope declaring only those derives an empty record,
/// which matches the empty one an absent file reads as: without this the
/// plan is empty, the verb says the scope is up to date, and no file
/// lands for verify, edit detection or the sweep to key off. That is the
/// state the version floor leaves behind once a person moves an older
/// lock aside.
///
/// An install this pass refused is not one of those. Its kind is planned
/// and would be recorded; there is simply nothing to record yet, and the
/// run closes on the conflict rather than on a write.
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
    // declares no unplanned install is done either way.
    if unchanged && !declares_unplanned_installs(manifest) {
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
