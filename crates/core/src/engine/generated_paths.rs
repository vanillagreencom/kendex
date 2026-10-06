//! Committed CI inventory derived from the artifacts the engine renders.
//! Carrier packages and in-place sources are executable source, not renders.
//!
//! The collection is a value rather than a step inside the write, because
//! two readers need it: the inventory this file writes, and the commit
//! offer, which tells the files kendex owns whole from the ones it writes
//! into. One collection, so the two cannot disagree about what kendex
//! wrote.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use crate::apply::{Op, PlannedOp, Pre};
use crate::env::Env;
use crate::error::Result;
use crate::model::{HarnessId, ItemKind, Scope};

use super::desired::{Artifact, DesiredState, Owns};
use super::instruction_shims::{ShimStanding, keyed_position, recorded_shims};

/// The name of the inventory CI reads, at a project root.
pub const INVENTORY: &str = ".kendex-generated.json";

mod adopted;
pub use adopted::AdoptedWorkflow;
pub(crate) use adopted::{committable_paths, inventory_paths};

/// The files that travel with a commit that adds or takes away a render:
/// the inventory recording which paths kendex owns here, and the lock
/// recording what each render is and where it came from — without which a
/// clone reads every render as files kendex never wrote.
///
/// The manifest is deliberately not here. kendex writes keys in it and folds
/// them into the document the person wrote — `crate::manifest::fold` keeps
/// their comments, key order and every value it did not touch — so kendex
/// does not own its bytes and never restores it whole. A commit carries it
/// only where the action wrote it and it held no change before, and
/// otherwise the offer names it to the person
/// ([`crate::commit_offer::Pending::manifest_not_carried`]). A
/// source catalog moves the declaration to a sibling file
/// (`crate::manifest::project_manifest_path`), so a fixed name here would
/// name the wrong file in this very repository.
pub fn companions(root: &Path) -> [PathBuf; 2] {
    [root.join(INVENTORY), root.join(crate::lock::LOCK_FILE)]
}

/// What kendex renders in one project, split by whether it owns the whole
/// file.
///
/// The split is what the commit offer needs and the inventory does not: a
/// shared configuration file kendex writes one key in cannot be committed
/// on its own, because git commits whole files and the person's own keys
/// live in the same one.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GeneratedPaths {
    /// Files kendex writes end to end: rendered agents, skill trees and
    /// their links, registration scripts, `CLAUDE.md` shims.
    pub whole: BTreeSet<PathBuf>,
    /// Shared configuration files kendex writes one key in — the
    /// `Registration` edit targets and Gemini's instruction shim.
    /// `desired.rs` states why kendex edits rather than renders them: every
    /// unrelated key in them stays intact.
    pub shared: BTreeSet<PathBuf>,
    /// Shared configuration files this pass edits keys in or, where its
    /// edits leave nothing in one, takes away. A removal reverses a
    /// registration in a file no item names after it, so
    /// [`GeneratedPaths::shared`] does not hold every one. Adds nothing to
    /// the inventory. Files kendex does not own whole: the person's own keys
    /// may be in them, so neither the edit nor the deletion is kendex's
    /// alone.
    pub edited: BTreeSet<PathBuf>,
    /// What the install record at `HEAD` says kendex writes keys in
    /// ([`recorded`]). Adds nothing to the inventory. A removal left
    /// uncommitted has taken its entry out of the record on disk and may
    /// have taken an emptied file away with it, and the inventory at `HEAD`
    /// still names that file: this is what keeps it a file kendex writes
    /// into rather than one it owns, for a reading made after the action as
    /// for the action's own.
    pub recorded: Recorded,
    /// Sections a renderer owns inside files whose other bytes belong to
    /// the project. Commit and restore can only change the named section.
    pub regions: BTreeSet<crate::commit_offer::OwnedRegion>,
    /// The positions of items this pass refused to write — a `Conflict` or
    /// `Unmanaged` row — as the other two groups would have carried them.
    pub held: BTreeSet<PathBuf>,
    /// Adoption copies checked against declared package templates. Refresh
    /// records their provenance but does not write or restore their YAML.
    pub adopted: BTreeMap<PathBuf, AdoptedWorkflow>,
}

/// What the install record at `HEAD` says about the shared configuration
/// files kendex writes keys in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Recorded {
    /// The record at `HEAD` read, or `HEAD` holds neither a record nor an
    /// inventory listing paths: these files.
    Known(BTreeSet<PathBuf>),
    /// `HEAD` holds a record this build does not read, or none while its
    /// inventory lists paths. That inventory cannot then tell a render from
    /// a shared file whose last key went, so a deletion it names is
    /// kendex's only where the record on disk names the path, or a tree
    /// holding it, as a file it wrote whole: `rendered`.
    Unknown { rendered: BTreeSet<PathBuf> },
}

impl Default for Recorded {
    fn default() -> Self {
        Recorded::Known(BTreeSet::new())
    }
}

impl Recorded {
    /// The files the record at `HEAD` names; none where it says nothing.
    fn files(&self) -> &BTreeSet<PathBuf> {
        static NONE: BTreeSet<PathBuf> = BTreeSet::new();
        match self {
            Recorded::Known(files) => files,
            Recorded::Unknown { .. } => &NONE,
        }
    }
}

impl GeneratedPaths {
    /// Nothing rendered at all, in either group.
    pub fn is_empty(&self) -> bool {
        self.whole.is_empty()
            && self.shared.is_empty()
            && self.regions.is_empty()
            && self.adopted.is_empty()
    }

    /// The inventory's paths, including its own file and the lock.
    pub fn inventory(&self, root: &Path) -> BTreeSet<PathBuf> {
        self.whole
            .iter()
            .chain(&self.shared)
            .chain(&self.held)
            .chain(self.adopted.keys())
            .cloned()
            .chain(
                self.regions
                    .iter()
                    .map(|region| region.path().to_path_buf()),
            )
            .chain(companions(root))
            .collect()
    }

    /// Every inventory path as the document spells it: relative to the
    /// root, slashed, and sorted by the set it comes out of. That order is
    /// the document's line order, so an entry added on two branches lands
    /// at the same line on both.
    ///
    /// This is the one derivation of that set. The write reaches it through
    /// [`GeneratedPaths::document`], `own_inventory.rs` reads it directly,
    /// and `verify` holds the committed inventory to it, so none decides
    /// what a render is a second time.
    pub fn relative(&self, root: &Path) -> BTreeSet<String> {
        Self::spelled(self.inventory(root).iter(), root)
    }

    fn spelled<'a>(paths: impl Iterator<Item = &'a PathBuf>, root: &Path) -> BTreeSet<String> {
        paths
            .filter_map(|path| path.strip_prefix(root).ok().map(crate::paths::slashed))
            .collect()
    }

    /// The inventory document, exactly as the write below lays it down: the
    /// write's serialization of [`GeneratedPaths::relative`], one entry per
    /// line in that set's order, and nothing besides.
    ///
    /// The layout is for git, not for a reader. Every reader — the check in
    /// `own_inventory.rs`, commit-guards' `generated-paths.sh`, the drift
    /// hook — parses the JSON back into a set and holds the committed copy
    /// to that. A merge reads lines: with the whole set on one line, any
    /// two branches adding renders conflict on that line and the resolution
    /// is an array composed by hand; one entry per line bounds a conflict to
    /// the lines holding the entries involved.
    fn document(&self, root: &Path) -> Result<String> {
        adopted::document(self, root)
    }

    /// Owning the FORMAT is not owning the bytes, so the project's manifest
    /// is not here: `crate::manifest::fold` exists because kendex edits the
    /// keys it holds and leaves the rest of that document alone. This set is
    /// what a restore writes over, and nothing kendex only edits keys in may
    /// be written over whole.
    pub fn owned(&self, root: &Path) -> BTreeSet<PathBuf> {
        self.whole
            .iter()
            .cloned()
            .chain(self.regions.iter().map(|region| region.path().to_owned()))
            .chain(companions(root))
            .collect()
    }

    /// These paths, with `edited` as the shared configuration files the
    /// pass edits or takes away ([`GeneratedPaths::edited`]) and `recorded`
    /// as the ones the record at `HEAD` writes keys in
    /// ([`GeneratedPaths::recorded`]).
    pub(super) fn editing(self, edited: BTreeSet<PathBuf>, recorded: Recorded) -> Self {
        Self {
            edited,
            recorded,
            ..self
        }
    }

    /// Every file an action can write into beside its renders without
    /// owning it whole: the project's manifest, its settings file,
    /// `.gitignore`, and the shared configuration files in
    /// [`GeneratedPaths::shared`], [`GeneratedPaths::edited`] and
    /// [`GeneratedPaths::recorded`]. What a
    /// reading before an action records as the action's writes where the
    /// caller holds no plan to name them
    /// ([`crate::commit_offer::Before::read`]): the app reads before a write
    /// it cannot see the plan of. A file among them the action left as it
    /// found it is the person's.
    pub fn beside(&self, root: &Path) -> BTreeSet<PathBuf> {
        self.shared
            .iter()
            .chain(&self.edited)
            .chain(self.recorded.files())
            .cloned()
            .chain([
                crate::manifest::project_manifest_path(root),
                crate::settings_seed::settings_file_path(root),
                root.join(".gitignore"),
            ])
            .collect()
    }

    /// The region ownership description for one relative project path.
    pub fn region<'a>(
        &'a self,
        root: &Path,
        path: &str,
    ) -> Option<&'a crate::commit_offer::OwnedRegion> {
        let whole = root.join(path);
        self.regions.iter().find(|region| region.path() == whole)
    }
}

/// The positions one artifact writes, split as [`GeneratedPaths`] splits
/// them: the files owned whole, then the shared edit targets.
///
/// Read off [`Artifact::positions`], so where an installation sits is
/// decided once. The inventory lists files, not directories — a reader
/// holds each committed path to it — so a tree position is spelled out
/// here as the files rendered under it.
fn positions(artifact: &Artifact) -> (Vec<PathBuf>, Vec<PathBuf>) {
    let mut whole = Vec::new();
    let mut shared = Vec::new();
    for position in artifact.positions() {
        match position.owns {
            Owns::File => whole.push(position.path),
            Owns::Keys => shared.push(position.path),
            Owns::Tree => {
                let Artifact::Tree { files, .. } = artifact else {
                    unreachable!("a tree position comes from a tree artifact")
                };
                whole.extend(files.iter().map(|(path, _)| position.path.join(path)));
            }
        }
    }
    (whole, shared)
}

/// The paths this pass renders, by group.
///
/// An in-place source tree is out, its links with it: it is the person's
/// source, not a render. A copy delivered from an in-place declaration is
/// a render like any other.
fn collect(
    state: &DesiredState,
    shims: &[ShimStanding],
    drift: &[super::DriftRow],
) -> GeneratedPaths {
    let mut generated = GeneratedPaths::default();
    for item in &state.items {
        if matches!(item.artifact, Artifact::Tree { in_place: true, .. }) {
            continue;
        }
        let refused = drift.iter().any(|row| {
            row.kind == item.kind
                && row.name == item.name
                && row.harness == item.harness
                && matches!(
                    row.state,
                    super::DriftState::Conflict | super::DriftState::Unmanaged
                )
        });
        let (whole, shared) = positions(&item.artifact);
        if refused {
            generated.held.extend(whole);
            generated.held.extend(shared);
            continue;
        }
        generated.whole.extend(whole);
        generated.shared.extend(shared);
    }
    for shim in shims.iter().filter(|shim| shim.kept()) {
        let position = shim.position();
        match position.owns {
            Owns::File => generated.whole.insert(position.path),
            Owns::Keys => generated.shared.insert(position.path),
            Owns::Tree => unreachable!("a shim is a file or a key in one, never a tree"),
        };
    }
    generated
}

/// The shared configuration files the install record at `HEAD` has kendex
/// writing keys in: the file each registration it records is reversed in
/// ([`super::owned::installed`]), the one answer to what an installation
/// wrote, and the file each keyed shim it records sits in, the inventory at
/// `HEAD` seeding a record that lacks one as the retirement's does
/// ([`recorded_shims`]). Read at `HEAD` and not off the record on disk,
/// which an uncommitted removal has already taken the entry out of.
///
/// A scope that is not a project, a project outside git, an unborn `HEAD`
/// and one holding neither a record nor an inventory listing paths name
/// none. A record at `HEAD` this build will not read, or none beside such
/// an inventory, is [`Recorded::Unknown`] with what `lock`, the record on
/// disk the plan reads, names whole: refusing here would fail every plan
/// over a copy only the commit offer's deletion rule consults.
pub(super) fn recorded(env: &Env, scope: &Scope, lock: &crate::lock::Lock) -> Result<Recorded> {
    let Scope::Project { root } = scope else {
        return Ok(Recorded::default());
    };
    if !root.join(".git").exists() {
        return Ok(Recorded::default());
    }
    let committed = crate::commit_offer::committed(root, crate::lock::LOCK_FILE).map_err(
        git_failed("read committed install record", "install record"),
    )?;
    let path = crate::lock::lock_path(env, scope);
    let at_head = match committed {
        Some(bytes) => crate::lock::parse_text(&path, &String::from_utf8_lossy(&bytes)).ok(),
        None => {
            let inventory = crate::commit_offer::committed_inventory(root).map_err(git_failed(
                "read committed generated inventory",
                "inventory",
            ))?;
            if inventory.is_empty() {
                return Ok(Recorded::default());
            }
            None
        }
    };
    let Some(at_head) = at_head else {
        return Ok(Recorded::Unknown {
            rendered: super::owned::paths(env, scope, lock),
        });
    };
    let mut recorded = BTreeSet::new();
    for entry in at_head.entries.values() {
        let edits = super::owned::installed(env, scope, entry).edits?;
        recorded.extend(edits.into_iter().map(|(path, _)| path));
    }
    let shims = recorded_shims(env, scope, root, &at_head.shims, || {
        crate::commit_offer::committed_inventory(root).map_err(git_failed(
            "read committed generated inventory",
            "inventory",
        ))
    })?;
    recorded.extend(
        shims
            .into_iter()
            .map(|shim| keyed_position(env, scope, shim)),
    );
    Ok(Recorded::Known(recorded))
}

/// A read of the last commit that would not run, as the plan's error:
/// `command` names the read and `what` the thing it reads.
fn git_failed(
    command: &'static str,
    what: &'static str,
) -> impl FnOnce(crate::commit_offer::Failed) -> crate::error::CoreError {
    move |error| crate::error::CoreError::GitFailed {
        command: command.to_owned(),
        stderr: if error.timed_out() {
            format!("{what} read timed out")
        } else {
            error.said().join("\n")
        },
    }
}

/// Collect what this pass renders and plan the inventory write for it.
/// The collection is handed back so the report can carry it to the commit
/// offer: one collection, so the inventory and the offer cannot disagree.
/// `unrendered` is [`Unrendered::of`]: an adopted workflow still at the
/// bytes of a template in a leaving tree leaves with its package, and a
/// package kept as recorded keeps its rows.
pub(super) fn plan(
    scope: &Scope,
    state: &DesiredState,
    shims: &[ShimStanding],
    drift: &[super::DriftRow],
    unrendered: &Unrendered,
    ops: &mut Vec<PlannedOp>,
) -> Result<GeneratedPaths> {
    let mut generated = collect(state, shims, drift);
    let Scope::Project { root } = scope else {
        return Ok(generated);
    };
    if !root.join(".git").exists() {
        return Ok(generated);
    }
    let Some(adopted) = adopted::collect(root, state, unrendered, ops)? else {
        // Verify reports the malformed document. An apply must retain it:
        // rewriting it could erase adoption declarations it cannot read.
        return Ok(generated);
    };
    generated.adopted = adopted;
    let kept = &unrendered.recorded;
    if !generated.held.is_empty() || !kept.is_empty() {
        let committed = crate::commit_offer::committed_inventory(root).map_err(git_failed(
            "read committed generated inventory",
            "inventory",
        ))?;
        generated.held.retain(|path| {
            path.strip_prefix(root)
                .ok()
                .is_some_and(|relative| committed.contains(&crate::paths::slashed(relative)))
        });
        kept.list(root, &committed, &mut generated);
    }
    let path = root.join(INVENTORY);
    // A project that renders nothing gets no inventory, and one that
    // already has one keeps it current even when it empties out.
    if generated.is_empty() && !path.exists() {
        return Ok(generated);
    }
    let existing = crate::fs::read_if_exists(&path)?;
    let newline = crate::fs::line_terminator(existing.as_deref().unwrap_or_default());
    let text = generated.document(root)?.replace('\n', newline);
    if existing.as_deref() == Some(&text) {
        return Ok(generated);
    }
    ops.push(PlannedOp {
        description: "Record generated paths for CI".to_owned().into(),
        op: Op::WriteFile {
            pre: Pre::observed(&path)?,
            path,
            bytes: text.into_bytes(),
        },
    });
    Ok(generated)
}

/// What the record says each package this pass keeps as recorded, and no
/// declared item renders, wrote: an item its catalog retired, on each tool
/// it stays on ([`super::desired::Retirement::kept`]), and a member a
/// declared set this pass cannot expand keeps
/// ([`DesiredState::kept_members`]). Read off the record this pass writes,
/// so a removal or a prune that takes the package takes its rows.
///
/// The record names a tree, not the files in it, and the pass reads no
/// source for the package, so the rows are the committed inventory's under
/// these positions: what the last render listed.
#[derive(Debug, Default)]
struct KeptPositions {
    /// The whole files and trees each wrote.
    whole: Vec<PathBuf>,
    /// The shared configuration files each writes keys in.
    shared: BTreeSet<PathBuf>,
}

impl KeptPositions {
    fn of(
        env: &Env,
        scope: &Scope,
        state: &DesiredState,
        after: &crate::lock::Lock,
    ) -> Result<KeptPositions> {
        let rendered: BTreeSet<(ItemKind, &str, HarnessId)> = state
            .items
            .iter()
            .map(|item| (item.kind, item.name.as_str(), item.harness))
            .collect();
        let mut kept = KeptPositions::default();
        for (key, entry) in &after.entries {
            let retired = state
                .retired
                .get(&(entry.kind, entry.name.clone()))
                .is_some_and(|retirement| retirement.kept.contains(&entry.harness));
            if !(retired || state.kept_members.contains_key(key))
                || rendered.contains(&(entry.kind, entry.name.as_str(), entry.harness))
            {
                continue;
            }
            let owned = super::owned::installed(env, scope, entry);
            kept.whole.extend(owned.files);
            kept.shared
                .extend(owned.edits?.into_iter().map(|(path, _)| path));
        }
        Ok(kept)
    }

    fn is_empty(&self) -> bool {
        self.whole.is_empty() && self.shared.is_empty()
    }

    /// Adds the rows of `committed`, the inventory at `HEAD`, that these
    /// positions hold to `generated`, in the group a render's rows go to.
    fn list(&self, root: &Path, committed: &BTreeSet<String>, generated: &mut GeneratedPaths) {
        for row in committed {
            let path = root.join(row);
            if self.shared.contains(&path) {
                generated.shared.insert(path);
            } else if self.whole.iter().any(|position| path.starts_with(position)) {
                generated.whole.insert(path);
            }
        }
    }
}

/// What the records say about the positions no declared item renders this
/// pass: the installed trees an adopted workflow's template can sit in, and
/// the rows a package kept as recorded keeps.
#[derive(Debug, Default)]
pub(super) struct Unrendered {
    /// Every package this pass takes out of the scope: its kind and name
    /// are in the old record and not in the new one. A tree one tool drops
    /// while another keeps the package is not among them.
    leaving: Vec<PathBuf>,
    /// Every retired package this pass keeps as recorded, and every
    /// member a retired set keeps.
    kept: Vec<PathBuf>,
    /// Every package this pass keeps as recorded.
    recorded: KeptPositions,
}

impl Unrendered {
    /// Read off the positions the records wrote: `before` the record this
    /// pass read, `after` the one it writes.
    pub(super) fn of(
        env: &Env,
        scope: &Scope,
        state: &DesiredState,
        before: &crate::lock::Lock,
        after: &crate::lock::Lock,
    ) -> Result<Unrendered> {
        let staying: BTreeSet<(ItemKind, &str)> = after
            .entries
            .values()
            .map(|entry| (entry.kind, entry.name.as_str()))
            .collect();
        let trees = |lock: &crate::lock::Lock,
                     keep: &dyn Fn(&str, &crate::lock::LockEntry) -> bool| {
            lock.entries
                .iter()
                .filter(|(key, entry)| keep(key, entry))
                .flat_map(|(_, entry)| super::owned::installed(env, scope, entry).files)
                .collect()
        };
        Ok(Unrendered {
            leaving: trees(before, &|_, entry| {
                !staying.contains(&(entry.kind, entry.name.as_str()))
            }),
            kept: trees(after, &|key, entry| {
                let retired = (entry.kind, entry.name.clone());
                state.retired.contains_key(&retired) || state.kept_by_retired_bundle(key)
            }),
            recorded: KeptPositions::of(env, scope, state, after)?,
        })
    }

    /// Whether `template` sits in a tree this pass takes away.
    fn leaving_holds(&self, template: &Path) -> bool {
        self.leaving.iter().any(|tree| template.starts_with(tree))
    }

    /// Whether `template` sits in a retired package this pass keeps.
    fn kept_holds(&self, template: &Path) -> bool {
        self.kept.iter().any(|tree| template.starts_with(tree))
    }
}

/// This repository's own committed inventory, held to what this pass
/// renders. Its own file: the check needs a message of its own.
#[cfg(all(test, unix))]
mod own_inventory;

/// This repository's committed renders, held to the bytes this pass
/// renders.
#[cfg(all(test, unix))]
mod own_renders;

/// The document's on-disk shape, which is what a merge reads.
#[cfg(test)]
mod tests;
