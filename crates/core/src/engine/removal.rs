use std::collections::BTreeSet;
use std::path::PathBuf;

use super::desired;
use super::owned::{Owned, installed};
use super::targets::disabled_name;
use super::{DriftRow, DriftState, PlanOptions};
use crate::apply::{Op, PlannedOp, Pre};
use crate::env::Env;
use crate::error::Result;
use crate::lock::{Lock, LockEntry};
use crate::manifest::Manifest;
use crate::model::{ItemKind, Scope};

/// Whether the user's hands are (or may be) on this installation's bytes.
/// Automatic removals — refusals, sweeps, orphan cleanup nobody named —
/// only take content they can prove is ours: every content path must hash
/// to what apply last wrote. A record from before that hash existed cannot
/// prove anything, so any content present holds. Explicitly asked-for
/// removals are not gated here: the trash keeps what they take.
pub fn edit_holds(env: &Env, scope: &Scope, entry: &LockEntry) -> bool {
    if !matches!(
        entry.kind,
        ItemKind::Skill | ItemKind::Agent | ItemKind::Command | ItemKind::Hook
    ) {
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
pub(super) fn trash(description: String, path: PathBuf) -> Result<PlannedOp> {
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
        op: Op::Trash { path, pre },
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
                    ),
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
/// the same tree twice: the second op finds nothing there and fails the
/// whole apply.
pub(super) struct TrashGuard {
    keep: BTreeSet<PathBuf>,
    trashed: BTreeSet<PathBuf>,
}

impl TrashGuard {
    pub(super) fn new(items: &[desired::Desired]) -> TrashGuard {
        let keep = items
            .iter()
            .flat_map(|item| desired::artifact_paths(&item.artifact))
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

/// An earlier install of a still-declared item wrote somewhere this one will
/// not: a codex command whose emitted name changed when a skill claimed it.
/// The tree it left is ours and nobody wants it now — without this it stays
/// on disk forever, offered by the tool under a name nobody declared.
pub(super) fn stale_emitted(
    state: &desired::DesiredState,
    lock: &Lock,
    guard: &mut TrashGuard,
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    for item in &state.items {
        let Some(entry) = lock.entries.get(&item.key) else {
            continue;
        };
        let Some(previous) = entry.emitted.as_ref() else {
            continue;
        };
        let current = item.emitted.iter().flat_map(|e| e.paths.iter());
        for path in &previous.paths {
            if current.clone().any(|kept| kept == path) {
                continue;
            }
            if !path.exists() && !path.is_symlink() {
                continue;
            }
            // Bytes that cannot be proven ours stay put — a re-shaped
            // artifact must not cost the user an edit they made under the
            // old shape.
            if !path.is_symlink()
                && entry.rendered_hash.as_ref().is_none_or(|rendered| {
                    crate::hash::hash_tree(path)
                        .map(|disk| &disk != rendered)
                        .unwrap_or(true)
                })
            {
                continue;
            }
            let planned = trash(
                format!(
                    "Move {} {}'s old files to the trash",
                    item.kind.name(),
                    item.name
                ),
                path.clone(),
            )?;
            guard.extend(ops, [planned]);
        }
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub(super) fn orphans(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    state: &desired::DesiredState,
    options: &PlanOptions,
    legacy_pi: &super::pi_hooks_move::Preflight,
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
        // The caller named this installation: an instruction about this exact
        // item, not a judgement about what anything still wants.
        let named = match &options.removal_filter_typed {
            Some(pairs) => pairs
                .iter()
                .any(|(kind, name)| *kind == entry.kind && name == &entry.name),
            None => options
                .removal_filter
                .as_ref()
                .is_some_and(|names| names.contains(&entry.name)),
        };
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
        });
        if !removable {
            if unneeded {
                sweepable.push(super::SetChange::dropped(scope, entry));
            }
            new_lock.entries.insert(key.clone(), entry.clone());
            continue;
        }
        // An installation the reserved-name move is holding is still
        // live and still kendex's to account for: its record is the only
        // thing a later pass can claim those files with, so it outlives
        // the sweep whatever else this pass was told to remove.
        if entry.kind == ItemKind::Hook
            && entry.harness == crate::model::HarnessId::Pi
            && let Some(hold) = legacy_pi.hold(&entry.name)
        {
            // The same causes, said the same way as on the path where the
            // item is still declared: only the line for an edit differs,
            // because what finishing the move means here is taking the
            // copy away rather than replacing it.
            let (detail, cause) = hold.row(
                "no longer wanted, but its copy under the directory pi reserved is not the one kendex wrote — that copy still runs; discard the edits to finish moving it, or take it away by hand",
            );
            drift.push(DriftRow {
                kind: entry.kind,
                name: entry.name.clone(),
                harness: entry.harness,
                scope: scope.clone(),
                state: DriftState::Conflict,
                detail,
                cause,
            });
            new_lock.entries.insert(key.clone(), entry.clone());
            continue;
        }
        // An automatic removal (a sweep, an unfiltered orphan cleanup)
        // never takes edited or unprovable bytes; only naming the item —
        // or asking for edits to be discarded — does.
        if !named && !options.overwrite_edited && edit_holds(env, scope, entry) {
            drift.push(DriftRow {
                kind: entry.kind,
                name: entry.name.clone(),
                harness: entry.harness,
                scope: scope.clone(),
                state: DriftState::Conflict,
                detail: "no longer wanted, but its files were edited on disk — remove it by name to confirm".into(),
                cause: Some(super::DriftCause::LocalEdit),
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
