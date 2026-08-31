use std::collections::BTreeSet;
use std::path::PathBuf;

use super::desired;
use super::owned::{Owned, installed};
use super::targets::disabled_name;
use super::{DriftRow, DriftState, PlanOptions};
use crate::apply::{Description, Op, PlannedOp, Pre};
use crate::env::Env;
use crate::error::Result;
use crate::lock::{Lock, LockEntry};
use crate::manifest::Manifest;
use crate::model::{ItemKind, Scope};

/// Whether the user's hands are (or may be) on this installation's bytes.
/// Automatic removals — refusals, sweeps, orphan cleanup nobody named —
/// only take content they can prove is ours: every content path must hash
/// to what apply last wrote. A record that cannot prove that holds
/// whatever content is present, hooks included. Explicitly asked-for
/// removals are not gated here: the trash keeps what they take.
pub fn edit_holds(env: &Env, scope: &Scope, entry: &LockEntry) -> bool {
    // A hook with no anchor used to sweep, read as the common stock of
    // older installs that holding would exempt from cleanup for good. The
    // version floor makes that reading false: a lock this build did not
    // write is refused before any of this runs, so an absent anchor is no
    // longer an old install. It is a current record this build cannot
    // account for, and a removal that cannot prove the bytes are ours does
    // not take them. The rule is the anchor, not the harness.
    let holdable = matches!(
        entry.kind,
        ItemKind::Skill | ItemKind::Agent | ItemKind::Command | ItemKind::Hook
    );
    if !holdable {
        return false;
    }
    let Owned { files, .. } = installed(env, scope, entry);
    let candidates: Vec<PathBuf> = files
        .iter()
        .flat_map(|path| [disabled_name(path), path.clone()])
        .filter(|path| !path.is_symlink() && path.exists())
        .collect();
    let Some(rendered) = &entry.rendered_hash else {
        return !candidates.is_empty();
    };
    candidates.iter().any(|path| {
        crate::hash::hash_tree(path)
            .map(|disk| &disk != rendered)
            .unwrap_or(true)
    })
}

/// A removal binds to what the preview showed, like every other mutation
/// (invariant 7): the exact bytes for a file or tree, the exact target for a
/// link we manage. Anything edited between preview and apply fails the
/// precondition and the whole apply rolls back, instead of moving work
/// nobody looked at into the trash.
pub(super) fn trash(description: Description, path: PathBuf) -> Result<PlannedOp> {
    let pre = match path.is_symlink() {
        true => Pre::SymlinkTo {
            target: std::fs::read_link(&path).map_err(|e| crate::error::CoreError::io(&path, e))?,
        },
        false => Pre::HashIs {
            hash: crate::hash::hash_tree(&path)?,
        },
    };
    Ok(PlannedOp {
        description,
        op: Op::Trash {
            path,
            pre,
            // The end state a removal asks for is that nothing is here,
            // and a copy already gone is that end state.
            absent_is_done: true,
        },
    })
}

/// Everything undoing one installation takes: the artifacts we wrote go to
/// the trash, registrations are reversed by a structured edit routed
/// through the per-file collector — a removal and an install editing the
/// same settings file must land in one mutation. Nothing is planned that
/// would not change the disk, and nothing outside what this entry
/// installed is touched (invariant 6).
pub(super) fn removal_ops(
    env: &Env,
    scope: &Scope,
    entry: &LockEntry,
    config_edits: &mut super::config_edits::ConfigEditPlan,
) -> Result<Vec<PlannedOp>> {
    let Owned { files, edits } = installed(env, scope, entry);
    let mut ops = Vec::new();
    for path in files {
        for candidate in [disabled_name(&path), path] {
            if candidate.exists() || candidate.is_symlink() {
                ops.push(trash(
                    format!(
                        "Move {} {}'s files to the trash",
                        entry.kind.name(),
                        entry.name
                    )
                    .into(),
                    candidate,
                )?);
            }
        }
    }
    for (path, edit) in edits {
        // An absent config file has nothing of ours in it; creating one to
        // record a removal would be the opposite of removing.
        let Some(current) = crate::fs::read_if_exists(&path)? else {
            continue;
        };
        let updated =
            edit.apply(&current)
                .map_err(|message| crate::error::CoreError::ConfigEdit {
                    path: path.clone(),
                    message,
                })?;
        if updated == current {
            continue;
        }
        config_edits.push(
            path,
            format!("remove {} for {}", entry.name, entry.harness.display_name()),
            edit,
        );
    }
    Ok(ops)
}

/// Which paths a Trash op may still take. Several lock entries name one
/// physical tree — codex and pi read the same skill directory — so a removal
/// must not move a tree another installation still wants, and must not move
/// the same tree twice: one tree is one op and one line in the preview, not
/// a second op with nothing left to do.
pub(super) struct TrashGuard {
    keep: BTreeSet<PathBuf>,
    trashed: BTreeSet<PathBuf>,
}

impl TrashGuard {
    pub(super) fn new(items: &[desired::Desired]) -> TrashGuard {
        let keep = items
            .iter()
            .flat_map(|item| item.artifact.paths())
            .collect();
        TrashGuard {
            keep,
            trashed: BTreeSet::new(),
        }
    }

    fn allows(&mut self, op: &Op) -> bool {
        let Op::Trash { path, .. } = op else {
            return true;
        };
        !self.keep.contains(path) && self.trashed.insert(path.clone())
    }

    pub(super) fn extend(
        &mut self,
        ops: &mut Vec<PlannedOp>,
        planned: impl IntoIterator<Item = PlannedOp>,
    ) {
        ops.extend(planned.into_iter().filter(|p| self.allows(&p.op)));
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) fn orphans(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    state: &desired::DesiredState,
    options: &PlanOptions,
    refused_keys: &BTreeSet<String>,
    guard: &mut TrashGuard,
    drift: &mut Vec<DriftRow>,
    ops: &mut Vec<PlannedOp>,
    config_edits: &mut super::config_edits::ConfigEditPlan,
    new_lock: &mut Lock,
) -> Result<Vec<super::SetChange>> {
    let desired_keys: BTreeSet<&String> = state.items.iter().map(|d| &d.key).collect();
    let mut sweepable = Vec::new();

    for (key, entry) in &lock.entries {
        if desired_keys.contains(key) || refused_keys.contains(key) {
            continue;
        }
        // Declared but skipped this pass (pending/disabled source, missing
        // from source): keep the record, it is not an orphan. A declaration
        // that did resolve has already said everything it wants installed,
        // so an entry it did not ask for — a harness dropped from its list —
        // is stranded and must be cleaned up like any other orphan.
        let unreachable_source = manifest.declared(entry.kind).contains_key(&entry.name)
            && !state.processed.contains(&(entry.kind, entry.name.clone()));
        let named = options.named_for_removal(entry.kind, &entry.name);
        // An installation nobody declared was derived from one that was, and
        // the catalog it came from is where its reason is written down. With
        // that catalog offline, "nothing requires it anymore" is not
        // something this pass knows — so it keeps what it cannot account for.
        // Being named is not that judgement, and it still goes.
        let unreadable_origin = derived_only(entry)
            && !named
            && !origin_readable(env, scope, manifest, state, &entry.source);
        if unreachable_source || unreadable_origin {
            new_lock.entries.insert(key.clone(), entry.clone());
            continue;
        }
        let unneeded = derived_only(entry);
        let unfiltered = options.removal_filter.is_none() && options.removal_filter_typed.is_none();
        let removable = (options.remove_orphans && (named || unfiltered))
            || (options.sweep_unneeded && unneeded);
        drift.push(DriftRow {
            kind: entry.kind,
            name: entry.name.clone(),
            harness: entry.harness,
            scope: scope.clone(),
            state: DriftState::Orphaned,
            detail: if removable {
                "no longer wanted — will be removed".into()
            } else {
                "left over from an earlier setup; nothing needs it anymore".into()
            },
            cause: None,
            compared: None,
            also_in_the_way: Vec::new(),
        });
        if !removable {
            if unneeded {
                sweepable.push(super::SetChange::dropped(entry));
            }
            new_lock.entries.insert(key.clone(), entry.clone());
            continue;
        }
        // An automatic removal (a sweep, an unfiltered orphan cleanup)
        // never takes bytes a record could vouch for and does not —
        // `edit_holds`' doc draws that line; only naming the item, or
        // asking for edits to be discarded, takes what it holds.
        if !named && !options.overwrite_edited && edit_holds(env, scope, entry) {
            drift.push(DriftRow {
                kind: entry.kind,
                name: entry.name.clone(),
                harness: entry.harness,
                scope: scope.clone(),
                state: DriftState::Conflict,
                detail: "no longer wanted, but its files were edited on disk — remove it by name to confirm".into(),
                cause: Some(super::DriftCause::LocalEdit),
                compared: None,
                also_in_the_way: Vec::new(),
            });
            new_lock.entries.insert(key.clone(), entry.clone());
            continue;
        }
        guard.extend(ops, removal_ops(env, scope, entry, config_edits)?);
    }
    Ok(sweepable)
}

/// Whether this installation only ever existed for another item's sake —
/// nobody asked for it by name, so once nothing needs it, nothing does.
pub(super) fn derived_only(entry: &crate::lock::LockEntry) -> bool {
    !entry.reasons.contains(&crate::lock::Reason::Requested)
}

/// Whether the catalog behind an installation can be read right now. The
/// pass has usually resolved it already; a source no declaration named this
/// time is resolved here, because the last item that needed it going away is
/// exactly when this question gets asked.
pub(super) fn origin_readable(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    state: &desired::DesiredState,
    source: &str,
) -> bool {
    match state.sources.get(source) {
        Some(resolution) => matches!(resolution, crate::source::SourceState::Ready(_)),
        None => matches!(
            crate::source::resolve(env, scope, source, manifest),
            Ok(crate::source::SourceState::Ready(_))
        ),
    }
}
