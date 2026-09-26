use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use super::desired::{self, Withholding};
use super::owned::{Owned, installed};
use super::targets::disabled_name;
use super::{DriftRow, DriftState, PlanOptions};
use crate::apply::{Description, Op, PlannedOp, Pre};
use crate::env::Env;
use crate::error::Result;
use crate::lock::{Lock, LockEntry, Reason, entry_key};
use crate::manifest::Manifest;
use crate::model::{ItemKind, Scope};

use super::item_plan::KeptAsIs;
use super::origin::Origins;

/// Whether the user's hands are (or may be) on this installation's bytes.
/// Automatic removals — refusals, sweeps, orphan cleanup nobody named —
/// only take content they can prove is ours: every content path must hash
/// to what apply last wrote. A record that cannot prove that holds
/// whatever content is present, hooks included. Explicitly asked-for
/// removals and a hook withheld for a companion that will not run
/// (`Withholding::Requires`) are not gated here: the trash keeps what they
/// take.
pub fn edit_holds(env: &Env, scope: &Scope, entry: &LockEntry) -> bool {
    // A hook with no anchor is not the common stock of older installs
    // that holding would exempt from cleanup for good: a lock this build
    // did not write is refused by the version floor before any of this
    // runs, so an absent anchor is not an old install. It is a current
    // record this build cannot
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
        crate::hash::RenderedIdentity::from_path(path, true)
            .map(|disk| !disk.matches(rendered))
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
        let in_sync =
            edit.in_sync(&current)
                .map_err(|message| crate::error::CoreError::ConfigEdit {
                    path: path.clone(),
                    message,
                })?;
        if in_sync {
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
    protected: BTreeSet<PathBuf>,
    trashed: BTreeSet<PathBuf>,
}

impl TrashGuard {
    pub(super) fn new(items: &[desired::Desired], keep: BTreeSet<PathBuf>) -> TrashGuard {
        let protected = items
            .iter()
            .flat_map(|item| item.artifact.paths())
            .chain(keep.iter().cloned())
            .collect();
        TrashGuard {
            keep,
            protected,
            trashed: BTreeSet::new(),
        }
    }

    fn allows(&mut self, op: &Op) -> bool {
        let Op::Trash { path, .. } = op else {
            return true;
        };
        !self.protected.contains(path) && self.trashed.insert(path.clone())
    }

    pub(super) fn extend(
        &mut self,
        ops: &mut Vec<PlannedOp>,
        planned: impl IntoIterator<Item = PlannedOp>,
    ) {
        ops.extend(planned.into_iter().filter(|p| self.allows(&p.op)));
    }
}

/// What the orphan pass decided for one record, before any row or op is
/// written: every verdict is known before the first is acted on, so a
/// record a held one requires can be kept with it.
enum Verdict {
    /// Kept with no row, for want of an answer: its declaration's source
    /// is unreachable, or its origin will not read. What it requires stays
    /// with it, except a copy withheld for a companion that will not run,
    /// which is an answer, and what is known outranks what is not.
    Retained,
    /// Not removable under the options: the left-over row, and offered to
    /// a sweep where nothing needs it.
    Left { unneeded: bool },
    /// Removable, but the person's edits are in it: the removed row, the
    /// edit conflict, and the record kept.
    Held,
    /// Removable, but a record that stays installed requires it on this
    /// tool, directly or through others kept the same way: kept with it,
    /// since a hook left armed must not lose what it runs with.
    Needed { by: String },
    /// Removable: taken. Named for removal by the person, it goes whatever
    /// requires it — the choice is theirs, as it is when the catalog that
    /// would say what needs it is offline. Withheld for a companion that
    /// will not run here, it goes whatever the options, since a wrapper
    /// left armed refuses every call it guards: the row says why.
    Removed { named: bool, withheld: bool },
}

/// The row a withheld hook's installed copy leaves as it goes.
const WITHHELD: &str = "withheld: a hook it requires will not run here — will be removed";

/// The conflict a held orphan leaves, naming the remedy that takes it.
const EDITED: &str =
    "no longer wanted, but its files were edited on disk — remove it by name to confirm";

/// [`EDITED`] for an orphan something that stays derives: removing it by
/// name would keep it removed on every tool, from what still requires it
/// too, so the remedy is applying with edits discarded, which takes the
/// held copy and writes nothing down.
const EDITED_DERIVED: &str = "no longer wanted, but its files were edited on disk — apply with edits discarded to confirm; removing it by name would also keep it from every tool where something still requires or bundles it";

/// The conflict a held orphan leaves: [`EDITED_DERIVED`] where this plan
/// derives an item of its kind and name on some tool, [`EDITED`]
/// otherwise. The plan's own reasons are what its apply records and what
/// the removal's catalog reading finds again, so an edge only the catalog
/// knows counts, and one recorded from something going does not.
fn edited(state: &desired::DesiredState, entry: &LockEntry) -> &'static str {
    let derived = state.items.iter().any(|item| {
        item.kind == entry.kind && item.name == entry.name && derived_at_all(&item.reasons)
    });
    match derived {
        true => EDITED_DERIVED,
        false => EDITED,
    }
}

/// `decided_keys` are the records the refusal and withheld passes already
/// planned for; nothing here asks about them again. `kept`
/// is every record an earlier pass kept as it was in place of writing it,
/// whose requirements this pass keeps with it.
#[allow(clippy::too_many_arguments)]
pub(super) fn orphans(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    state: &desired::DesiredState,
    options: &PlanOptions,
    decided_keys: &BTreeSet<String>,
    kept: &KeptAsIs,
    guard: &mut TrashGuard,
    drift: &mut Vec<DriftRow>,
    ops: &mut Vec<PlannedOp>,
    config_edits: &mut super::config_edits::ConfigEditPlan,
    new_lock: &mut Lock,
    notes: &mut Vec<String>,
) -> Result<Vec<super::SetChange>> {
    let mut sweepable = Vec::new();
    let mut origins = Origins::default();
    let mut verdicts = verdicts(
        env,
        scope,
        manifest,
        lock,
        state,
        options,
        decided_keys,
        guard,
        &mut origins,
    );
    keep_what_kept_records_require(lock, kept, &mut verdicts);
    let row = |entry: &LockEntry, state, detail: String, cause| DriftRow {
        kind: entry.kind,
        name: entry.name.clone(),
        harness: entry.harness,
        scope: scope.clone(),
        state,
        detail,
        cause,
        compared: None,
        also_in_the_way: Vec::new(),
    };
    for (key, verdict) in verdicts {
        let entry = &lock.entries[key];
        match verdict {
            Verdict::Retained => {
                new_lock.entries.insert(key.clone(), entry.clone());
            }
            Verdict::Left { unneeded } => {
                drift.push(row(
                    entry,
                    DriftState::Orphaned,
                    "left over from an earlier setup; nothing needs it anymore".into(),
                    None,
                ));
                if unneeded {
                    sweepable.push(super::SetChange::dropped(entry));
                }
                new_lock.entries.insert(key.clone(), entry.clone());
            }
            Verdict::Held => {
                drift.push(row(
                    entry,
                    DriftState::Orphaned,
                    "no longer wanted — will be removed".into(),
                    None,
                ));
                drift.push(row(
                    entry,
                    DriftState::Conflict,
                    edited(state, entry).into(),
                    Some(super::DriftCause::LocalEdit),
                ));
                new_lock.entries.insert(key.clone(), entry.clone());
            }
            Verdict::Needed { by } => {
                drift.push(row(
                    entry,
                    DriftState::Orphaned,
                    format!("needed by {by}, which stays installed — kept with it"),
                    None,
                ));
                new_lock.entries.insert(key.clone(), entry.clone());
            }
            Verdict::Removed { withheld, .. } => {
                let detail = match withheld {
                    true => WITHHELD,
                    false => "no longer wanted — will be removed",
                };
                drift.push(row(entry, DriftState::Orphaned, detail.into(), None));
                if entry.kind == ItemKind::PiExtension {
                    match pi_removal(env, scope, entry) {
                        Ok(planned) => guard.extend(ops, planned),
                        // A removal planned over what it could not read
                        // would be one nobody looked at; the record stays
                        // until it can be.
                        Err(unread) => {
                            drift.push(row(
                                entry,
                                DriftState::Conflict,
                                format!(
                                    "Pi carrier cleanup could not read what it would take: {unread}; package and record were kept"
                                ),
                                None,
                            ));
                            new_lock.entries.insert(key.clone(), entry.clone());
                        }
                    }
                    continue;
                }
                guard.extend(ops, removal_ops(env, scope, entry, config_edits)?);
            }
        }
    }
    origins.notes(notes);
    Ok(sweepable)
}

/// The verdict on every record no pass has planned for, in key order,
/// before the dependency closure of the held ones is applied.
#[allow(clippy::too_many_arguments)]
fn verdicts<'a>(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &'a Lock,
    state: &desired::DesiredState,
    options: &PlanOptions,
    decided_keys: &BTreeSet<String>,
    guard: &TrashGuard,
    origins: &mut Origins,
) -> Vec<(&'a String, Verdict)> {
    let desired_keys: BTreeSet<&String> = state.items.iter().map(|d| &d.key).collect();
    // The copies withheld for a companion that will not run there. A
    // wrapper left armed refuses every call it guards, so such a copy
    // comes out whatever the options and whatever its catalog says, the
    // person's edits with it.
    let lacking: BTreeSet<String> = state
        .withheld
        .iter()
        .filter(|(_, withheld)| withheld.because == Withholding::Requires)
        .map(|((kind, name, harness), _)| entry_key(*kind, name, *harness))
        .collect();
    let mut verdicts = Vec::new();
    for (key, entry) in &lock.entries {
        if desired_keys.contains(key) || decided_keys.contains(key) {
            continue;
        }
        let named = options.named_for_removal(entry.kind, &entry.name);
        if lacking.contains(key) {
            verdicts.push((
                key,
                Verdict::Removed {
                    named,
                    withheld: true,
                },
            ));
            continue;
        }
        // Declared but skipped this pass (pending/disabled source, missing
        // from source): keep the record, it is not an orphan. A declaration
        // that did resolve has already said everything it wants installed,
        // so an entry it did not ask for — a harness dropped from its list —
        // is stranded and must be cleaned up like any other orphan.
        let departed_harness = state.processed.contains(&(entry.kind, entry.name.clone()));
        let unreachable_source =
            manifest.declared(entry.kind).contains_key(&entry.name) && !departed_harness;
        // An installation something else brought in was derived from a
        // declaration, and the catalog it came from is where that reason is
        // written down. With that catalog offline, "nothing requires it" is not
        // something this pass knows — so it keeps what it cannot account for.
        // Being named is not that judgement, and it still goes.
        // `unreachable_source` has already decided to keep this one and is
        // reported per declaration, so asking here would only count it into
        // a retention it is not part of.
        let unreadable_origin = !unreachable_source
            && derived_at_all(&entry.reasons)
            && !named
            && !origins.readable(env, scope, manifest, state, &entry.source);
        if unreachable_source || unreadable_origin {
            verdicts.push((key, Verdict::Retained));
            continue;
        }
        let unneeded = derived_only(entry);
        let unfiltered = options.removal_filter.is_none();
        let removable = (options.remove_orphans && (named || unfiltered))
            || (options.sweep_unneeded && (unneeded || departed_harness));
        if !removable {
            verdicts.push((key, Verdict::Left { unneeded }));
            continue;
        }
        // An automatic removal (a sweep, an unfiltered orphan cleanup)
        // never takes bytes a record could vouch for and does not —
        // `edit_holds`' doc draws that line. Naming the item or discarding
        // edits takes what it holds into the trash.
        let mut removable_entry = entry.clone();
        if let Some(emitted) = &mut removable_entry.emitted {
            emitted.paths.retain(|path| !guard.keep.contains(path));
        }
        let takes_edits = named || options.overwrite_edited;
        let verdict = match !takes_edits && edit_holds(env, scope, &removable_entry) {
            true => Verdict::Held,
            false => Verdict::Removed {
                named,
                withheld: false,
            },
        };
        verdicts.push((key, verdict));
    }
    verdicts
}

/// A record that stays installed with its recorded bytes, whichever pass
/// kept it, keeps what it requires on its tool: every record an automatic
/// removal would take whose own recorded `RequiredBy` reason names a kept
/// record on the same tool becomes kept, until nothing changes. What stays
/// is read off one account and no list of passes: the records an earlier
/// pass kept as they were in place of writing them ([`KeptAsIs`]), and
/// every record this pass does not take. A record written this pass is not
/// among them, in sync with its old one or not: what it requires is
/// derived afresh, so a stale reason naming it keeps nothing. A record the
/// person named for removal is not an automatic removal and goes, and a
/// copy withheld for a companion that will not run goes unless its
/// requirer stays by an answer rather than for want of one
/// ([`Verdict::Retained`]). The requirer named is the one the row cites.
fn keep_what_kept_records_require(
    lock: &Lock,
    carried: &KeptAsIs,
    verdicts: &mut [(&String, Verdict)],
) {
    loop {
        // Every record that stays, and whether an answer keeps it.
        let kept: BTreeMap<&str, bool> = verdicts
            .iter()
            .filter_map(|(key, verdict)| match verdict {
                Verdict::Removed { .. } => None,
                Verdict::Retained => Some((key.as_str(), false)),
                Verdict::Left { .. } | Verdict::Held | Verdict::Needed { .. } => {
                    Some((key.as_str(), true))
                }
            })
            .collect();
        let mut changed = false;
        for (key, verdict) in verdicts.iter_mut() {
            let Verdict::Removed {
                named: false,
                withheld,
            } = *verdict
            else {
                continue;
            };
            let requirer = lock.entries[*key]
                .reasons
                .iter()
                .find_map(|reason| match reason {
                    Reason::RequiredBy { by } => {
                        let by_key = entry_key(by.kind, &by.name, by.harness);
                        let stays = carried.contains(&by_key)
                            || kept
                                .get(by_key.as_str())
                                .is_some_and(|answered| *answered || !withheld);
                        stays.then(|| by.name.clone())
                    }
                    Reason::Requested | Reason::MemberOf { .. } => None,
                });
            if let Some(by) = requirer {
                *verdict = Verdict::Needed { by };
                changed = true;
            }
        }
        if !changed {
            return;
        }
    }
}

/// One Pi package's removal: the op that takes its registrations and its
/// payload together, bound to the package tree as it sits (a move binds to
/// `TreeIs`, as every rename source does). `None` where nothing of it is on
/// disk to take and only the record goes. An error is something the plan
/// could not read — the scope's Pi root, its settings.json or the package's
/// own entries.
fn pi_removal(env: &Env, scope: &Scope, entry: &LockEntry) -> Result<Option<PlannedOp>> {
    let scope_root = crate::pi_ext::scope_root(env, scope)?;
    let registered = crate::pi_ext::registered(&scope_root, &entry.name)?;
    let package = crate::pi_ext::package_path(&scope_root, &entry.name)?;
    let pre = match crate::fs::entry(&package)? {
        Some(_) => Pre::tree_as_is(&package)?,
        None => Pre::Absent,
    };
    if !registered && pre.binds_nothing() {
        return Ok(None);
    }
    Ok(Some(PlannedOp {
        description: format!(
            "Move {} {}'s package to the trash and unregister it",
            entry.kind.name(),
            entry.name
        )
        .into(),
        op: Op::PiRemove {
            scope_root,
            name: entry.name.clone(),
            package,
            pre,
        },
    }))
}

/// Whether this installation only ever existed for another item's sake —
/// nobody asked for it by name, so once nothing needs it, nothing does.
fn derived_only(entry: &LockEntry) -> bool {
    !entry.reasons.contains(&Reason::Requested)
}

/// Whether anything derived an installation with these reasons at all — a
/// set carries it, or something requires it.
///
/// One entry can be both asked for by name and derived, and a declaration
/// dropped while its catalog will not read leaves exactly that entry: out of
/// desired state, with a derivation this pass cannot check. What a removal
/// gated on an unreadable origin has to know is whether a derivation is at
/// stake, which is not the same question as whether the person also asked
/// for it.
fn derived_at_all(reasons: &BTreeSet<Reason>) -> bool {
    reasons.iter().any(|reason| match reason {
        Reason::MemberOf { .. } | Reason::RequiredBy { .. } => true,
        Reason::Requested => false,
    })
}
