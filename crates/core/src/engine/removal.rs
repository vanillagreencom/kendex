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
use crate::pi_ext::PackageState;

use super::item_plan::KeptAsIs;
use super::origin::Origins;
use super::set_change::Said;

/// Whether the user's hands are (or may be) on this installation's bytes.
/// Automatic removals — refusals, sweeps, orphan cleanup nobody named —
/// only take content they can prove is ours: every content path must hash
/// to what apply last wrote. A record that cannot prove that holds
/// whatever content is present, hooks included. Explicitly asked-for
/// removals and a hook withheld for a companion that will not run
/// (`Withholding::Requires`) are not gated here: the trash keeps what they
/// take.
pub fn edit_holds(env: &Env, scope: &Scope, entry: &LockEntry) -> bool {
    if entry
        .output_style
        .as_ref()
        .is_some_and(|style| super::output_style::changed(style).unwrap_or(true))
    {
        return true;
    }
    // A hook with no anchor is not the common stock of older installs
    // that holding would exempt from cleanup for good: a lock this build
    // did not write is refused by the version floor before any of this
    // runs, so an absent anchor is not an old install. It is a current
    // record this build cannot
    // account for, and a removal that cannot prove the bytes are ours does
    // not take them. The rule is the anchor, not the harness.
    let holdable = matches!(
        entry.kind,
        ItemKind::Skill
            | ItemKind::Agent
            | ItemKind::Command
            | ItemKind::Hook
            | ItemKind::OutputStyle
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
    let edits = edits?;
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
#[derive(Clone)]
enum Verdict {
    /// Kept with no row, for want of an answer: its declaration's source
    /// is unreachable, or its origin will not read. What it requires stays
    /// with it, except a copy withheld for a companion that will not run,
    /// which is an answer, and what is known outranks what is not.
    Retained,
    /// Kept as recorded because its catalog retired it, and this pass
    /// neither prunes it, names it nor withholds it (`Retirement::kept`).
    /// Nothing renders it again, so its record is what its installed copy
    /// is held to: a copy gone or edited is a conflict row with the
    /// [`DriftCause::Retired`] cause. What it requires stays with it as for
    /// [`Retained`]; unlike that, it goes where a companion it requires
    /// goes ([`settle_lacking`]).
    ///
    /// [`DriftCause::Retired`]: super::DriftCause::Retired
    ///
    /// [`Retained`]: Verdict::Retained
    Retired,
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

/// The conflict a held orphan leaves, naming the remedy that takes it.
const EDITED: &str =
    "no longer wanted, but its files were edited on disk — remove it by name to confirm";

/// The conflict a kept retired item's copy leaves once its files are gone.
/// A prune takes the record with nothing left to hold.
const RETIRED_GONE: &str = "its catalog retired it and its installed files are gone — refresh with --prune takes the record, or remove it by name";

/// The conflict a kept retired item's copy leaves once its files were
/// edited: a prune holds the edits as it holds any orphan's, so only
/// naming it takes them.
const RETIRED_EDITED: &str = "its catalog retired it and its installed files were edited on disk — remove it by name to take them";

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
) -> Result<(Vec<super::SetChange>, Said)> {
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
    let lacking = settle_lacking(lock, kept, state, &mut verdicts);
    let said = said_of(lock, state, &verdicts, &lacking);
    let going = |said: Option<&str>| match said {
        Some(said) => format!("{said} — will be removed"),
        None => "no longer wanted — will be removed".to_owned(),
    };
    for (key, verdict) in verdicts {
        let entry = &lock.entries[key];
        let withheld = said.get(key).copied();
        match verdict {
            Verdict::Retained => {
                new_lock.entries.insert(key.clone(), entry.clone());
            }
            Verdict::Retired => {
                drift.extend(retired_copy(env, scope, entry));
                new_lock.entries.insert(key.clone(), entry.clone());
            }
            Verdict::Left { unneeded } => {
                drift.push(DriftRow {
                    remedy: Some(super::RowRemedy::Remove),
                    ..row(
                        scope,
                        entry,
                        DriftState::Orphaned,
                        withheld
                            .unwrap_or("left over from an earlier setup; nothing needs it anymore")
                            .into(),
                        None,
                    )
                });
                if unneeded {
                    sweepable.push(super::SetChange::dropped(entry, withheld));
                }
                new_lock.entries.insert(key.clone(), entry.clone());
            }
            Verdict::Held => {
                drift.push(row(
                    scope,
                    entry,
                    DriftState::Orphaned,
                    going(withheld),
                    None,
                ));
                drift.push(row(
                    scope,
                    entry,
                    DriftState::Conflict,
                    edited(state, entry).into(),
                    Some(super::DriftCause::LocalEdit),
                ));
                new_lock.entries.insert(key.clone(), entry.clone());
            }
            Verdict::Needed { by } => {
                drift.push(row(
                    scope,
                    entry,
                    DriftState::Orphaned,
                    format!("needed by {by}, which stays installed — kept with it"),
                    None,
                ));
                new_lock.entries.insert(key.clone(), entry.clone());
            }
            Verdict::Removed { .. } => {
                drift.push(row(
                    scope,
                    entry,
                    DriftState::Orphaned,
                    going(withheld),
                    None,
                ));
                if entry.kind == ItemKind::PiExtension {
                    match pi_removal(env, scope, entry, config_edits) {
                        Ok(planned) => guard.extend(ops, planned),
                        // A removal planned over what it could not read
                        // would be one nobody looked at; the record stays
                        // until it can be.
                        Err(unread) => {
                            drift.push(row(
                                scope,
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
    Ok((sweepable, said))
}

/// What each record's row and set change say of a withholding or a
/// missing companion that takes it ([`settle_lacking`]), in place of the
/// words for an orphan; a copy lacking a companion the walk did not
/// withhold it for says what a missing companion does.
fn said_of(
    lock: &Lock,
    state: &desired::DesiredState,
    verdicts: &[(&String, Verdict)],
    lacking: &BTreeSet<&String>,
) -> Said {
    verdicts
        .iter()
        .filter_map(|(key, _)| {
            let withheld = withheld_said(state, &lock.entries[*key]);
            let said = match lacking.contains(key) {
                true => withheld.or(Withholding::Requires.said()),
                false => withheld,
            };
            said.map(|said| ((*key).clone(), said))
        })
        .collect()
}

/// One row the orphan pass says about `entry`.
fn row(
    scope: &Scope,
    entry: &LockEntry,
    state: DriftState,
    detail: String,
    cause: Option<super::DriftCause>,
) -> DriftRow {
    DriftRow {
        kind: entry.kind,
        name: entry.name.clone(),
        harness: entry.harness,
        scope: scope.clone(),
        state,
        detail,
        cause,
        compared: None,
        also_in_the_way: Vec::new(),
        remedy: None,
    }
}

/// What a withholding that takes this copy says of it, in place of the
/// words for an orphan nothing withholds.
fn withheld_said(state: &desired::DesiredState, entry: &LockEntry) -> Option<&'static str> {
    let key = (entry.kind, entry.name.clone(), entry.harness);
    state.withheld.get(&key).and_then(|because| because.said())
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
        .filter(|(_, because)| **because == Withholding::Requires)
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
        // An item its catalog retired stays where it is kept
        // (`Retirement::kept`, which a removal by name leaves out) and the
        // walk does not withhold it; anywhere else it goes as a departed
        // declaration does.
        let retirement = state.retired.get(&(entry.kind, entry.name.clone()));
        let held = (entry.kind, entry.name.clone(), entry.harness);
        let withheld = state
            .withheld
            .get(&held)
            .is_some_and(|because| because.takes());
        if retirement.is_some_and(|retired| retired.kept.contains(&entry.harness)) && !withheld {
            verdicts.push((key, Verdict::Retired));
            continue;
        }
        // Declared but skipped this pass (pending/disabled source, missing
        // from source): keep the record, it is not an orphan. A declaration
        // that did resolve has already said everything it wants installed,
        // so an entry it did not ask for — a harness dropped from its list —
        // is stranded and must be cleaned up like any other orphan.
        let departed_harness = retirement.is_some()
            || state
                .processed
                .contains_key(&(entry.kind, entry.name.clone()));
        let unreachable_source = still_declared(manifest, entry) && !departed_harness;
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
        // Refresh's unfiltered sweep takes every record nothing declares or
        // derives anymore, a declaration deleted from the manifest or
        // renamed included, so a consumer holds only what its manifest and
        // catalog ship. A named removal does not sweep unrelated requested
        // items.
        let unfiltered = options.removal_filter.is_none();
        let removable = (options.remove_orphans && (named || unfiltered))
            || (options.sweep_unneeded && (unneeded || departed_harness || unfiltered));
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
        let edited = match entry.kind {
            ItemKind::PiExtension => pi_edit_holds(env, scope, entry),
            _ => edit_holds(env, scope, &removable_entry),
        };
        let verdict = match !takes_edits && edited {
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

/// Every verdict settled together with what the copies run with, the one
/// answer to whether a hook still has its companions: a switched-on hook
/// whose companion goes on its tool lacks it, and goes as one withheld
/// for a companion that will not run does, whatever the options and its
/// edits, so no hook is left armed beside nothing. Its companions are what
/// its record required there (each companion record's `RequiredBy`) and,
/// for a copy withheld for a retirement, the companions the walk took that
/// reason from (`DesiredState::retired_companions`), one with no record
/// there gone already. A companion goes where its own verdict takes it:
/// pruned, named, never recorded or itself lacking, whichever member of a
/// pair the person names. A copy that lacks a companion is never kept by
/// what requires it ([`keep_what_kept_records_require`]), and keeps
/// nothing it required, so every verdict is read again from the first ones
/// until no more copies lack one. A copy retained for want of an answer
/// is not asked: nothing is decided on it. Returns the copies that lack a
/// companion.
fn settle_lacking<'a>(
    lock: &Lock,
    carried: &KeptAsIs,
    state: &desired::DesiredState,
    verdicts: &mut Vec<(&'a String, Verdict)>,
) -> BTreeSet<&'a String> {
    let mut requires: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for (key, entry) in &lock.entries {
        for reason in &entry.reasons {
            if let Reason::RequiredBy { by } = reason {
                let requirer = entry_key(by.kind, &by.name, by.harness);
                requires.entry(requirer).or_default().push(key.clone());
            }
        }
    }
    for ((kind, name, harness), companions) in &state.retired_companions {
        let companions = companions
            .iter()
            .map(|(dep_kind, dep)| entry_key(*dep_kind, dep, *harness));
        requires
            .entry(entry_key(*kind, name, *harness))
            .or_default()
            .extend(companions);
    }
    let first = verdicts.clone();
    let mut lacking: BTreeSet<&'a String> = BTreeSet::new();
    loop {
        *verdicts = first.clone();
        for (key, verdict) in verdicts.iter_mut() {
            if lacking.contains(key) {
                let named = matches!(verdict, Verdict::Removed { named: true, .. });
                *verdict = Verdict::Removed {
                    named,
                    withheld: true,
                };
            }
        }
        keep_what_kept_records_require(lock, carried, &lacking, verdicts);
        let going: BTreeSet<&str> = verdicts
            .iter()
            .filter(|(_, verdict)| matches!(verdict, Verdict::Removed { .. }))
            .map(|(key, _)| key.as_str())
            .collect();
        let before = lacking.len();
        for (key, verdict) in verdicts.iter() {
            let entry = &lock.entries[*key];
            let asked = entry.kind == ItemKind::Hook
                && entry.enabled
                && !matches!(verdict, Verdict::Retained);
            let lacks = requires.get(key.as_str()).is_some_and(|companions| {
                companions.iter().any(|companion| {
                    !lock.entries.contains_key(companion) || going.contains(companion.as_str())
                })
            });
            if asked && lacks {
                lacking.insert(*key);
            }
        }
        if lacking.len() == before {
            return lacking;
        }
    }
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
    lacking: &BTreeSet<&String>,
    verdicts: &mut [(&String, Verdict)],
) {
    loop {
        // Every record that stays, and whether an answer keeps it.
        let kept: BTreeMap<&str, bool> = verdicts
            .iter()
            .filter_map(|(key, verdict)| match verdict {
                Verdict::Removed { .. } => None,
                Verdict::Retained | Verdict::Retired => Some((key.as_str(), false)),
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
            if lacking.contains(key) {
                continue;
            }
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
/// `TreeIs`, as every rename source does), and its `APPEND_SYSTEM.md` block
/// as an edit composed with that file's others. `None` where nothing of it
/// is on disk to take and only the record goes. An error is something the
/// plan could not read — the scope's Pi root, its settings.json, its append
/// file or the package's own entries — and plans no part of the removal.
fn pi_removal(
    env: &Env,
    scope: &Scope,
    entry: &LockEntry,
    config_edits: &mut super::config_edits::ConfigEditPlan,
) -> Result<Option<PlannedOp>> {
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
    let append = crate::pi_ext::append_system_target(env, &scope_root)?;
    let current = crate::fs::read_if_exists(&append)?.unwrap_or_default();
    if crate::configedit::marker_block(&current, &entry.name).is_some() {
        config_edits.push(
            append,
            format!("remove {} instructions", entry.name),
            crate::configedit::ConfigEdit::RemoveMarkerBlock {
                name: entry.name.clone(),
            },
        );
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

/// Whether the manifest still declares this record's item. A plugin
/// declares under its own table, on the one tool its declaration names.
fn still_declared(manifest: &Manifest, entry: &LockEntry) -> bool {
    match entry.kind {
        ItemKind::Plugin => manifest
            .plugins
            .get(&entry.name)
            .is_some_and(|decl| decl.harness == entry.harness),
        kind => manifest.declared(kind).contains_key(&entry.name),
    }
}

/// [`edit_holds`] for a Pi package: an automatic removal takes it only
/// where its installed files are the bytes its completed record names.
/// Files already gone hold nothing.
fn pi_edit_holds(env: &Env, scope: &Scope, entry: &LockEntry) -> bool {
    !matches!(
        pi_state(env, scope, entry),
        Ok(PackageState::Current { .. } | PackageState::Missing)
    )
}

/// Where a Pi package's installed files stand against its completed record.
fn pi_state(env: &Env, scope: &Scope, entry: &LockEntry) -> Result<PackageState> {
    crate::pi_ext::scope_root(env, scope).and_then(|root| {
        crate::pi_ext::installed_state(&root, &entry.name, entry.rendered_hash.as_deref())
    })
}

/// The conflict a kept retired item's installed copy raises against its
/// record, or `None` where every recorded file is there with the bytes the
/// record names. A file counts as there under its switched-off name too.
fn retired_copy(env: &Env, scope: &Scope, entry: &LockEntry) -> Option<DriftRow> {
    let detail = retired_copy_detail(env, scope, entry)?;
    Some(row(
        scope,
        entry,
        DriftState::Conflict,
        detail,
        Some(super::DriftCause::Retired),
    ))
}

/// What [`retired_copy`] says, where it says anything.
fn retired_copy_detail(env: &Env, scope: &Scope, entry: &LockEntry) -> Option<String> {
    let detail = match entry.kind {
        ItemKind::PiExtension => match pi_state(env, scope, entry) {
            Ok(PackageState::Current { .. }) => return None,
            Ok(PackageState::Missing) => RETIRED_GONE,
            Ok(PackageState::Different) => RETIRED_EDITED,
            Err(unread) => {
                return Some(format!(
                    "its catalog retired it and its installed package could not be compared: {unread}"
                ));
            }
        },
        _ => {
            let Owned { files, .. } = installed(env, scope, entry);
            let gone = files.iter().any(|path| {
                [disabled_name(path), path.clone()]
                    .iter()
                    .all(|candidate| !candidate.exists() && !candidate.is_symlink())
            });
            if gone {
                RETIRED_GONE
            } else if edit_holds(env, scope, entry) {
                RETIRED_EDITED
            } else {
                return None;
            }
        }
    };
    Some(detail.to_owned())
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
