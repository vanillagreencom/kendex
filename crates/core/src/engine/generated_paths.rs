//! Committed CI inventory derived from the artifacts the engine renders.
//! Carrier packages and in-place sources are executable source, not renders.
//!
//! The collection is a value rather than a step inside the write, because
//! two readers need it: the inventory this file writes, and the commit
//! offer, which covers only the files kendex owns whole. One collection,
//! so the two cannot disagree about what kendex wrote.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use crate::apply::{Op, PlannedOp, Pre};
use crate::error::Result;
use crate::model::Scope;

use super::desired::{Artifact, DesiredState, Owns};
use super::instruction_shims::{ShimStanding, ShimState};

/// The name of the inventory CI reads, at a project root.
pub const INVENTORY: &str = ".kendex-generated.json";

/// The files that travel with a commit that adds or takes away a render:
/// the inventory recording which paths kendex owns here, and the lock
/// recording what each render is and where it came from — without which a
/// clone reads every render as files kendex never wrote.
///
/// The manifest is deliberately not here. kendex writes keys in it and folds
/// them into the document the person wrote — `crate::manifest::fold` keeps
/// their comments, key order and every value it did not touch — so kendex
/// does not own its bytes and may neither commit nor restore it whole. A
/// source catalog moves the declaration to a sibling file besides
/// (`crate::manifest::project_manifest_path`), so a fixed name here would
/// name the wrong file in this very repository. The declaration a render
/// does need to survive a later apply is that manifest, and the offer names
/// it to the person rather than committing it:
/// [`crate::commit_offer::Pending::manifest_not_carried`].
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
    /// their links, registration scripts, instruction shims.
    pub whole: BTreeSet<PathBuf>,
    /// Shared configuration files kendex writes one key in — the
    /// `Registration` edit targets. `desired.rs` states why kendex edits
    /// rather than renders them: every unrelated key in them stays intact.
    pub shared: BTreeSet<PathBuf>,
    /// Sections a renderer owns inside files whose other bytes belong to
    /// the project. Commit and restore can only change the named section.
    pub regions: BTreeSet<crate::commit_offer::OwnedRegion>,
    /// The positions of items this pass refused to write — a `Conflict` or
    /// `Unmanaged` row — as the other two groups would have carried them.
    pub held: BTreeSet<PathBuf>,
}

impl GeneratedPaths {
    /// Nothing rendered at all, in either group.
    pub fn is_empty(&self) -> bool {
        self.whole.is_empty() && self.shared.is_empty() && self.regions.is_empty()
    }

    /// The inventory's paths, including its own file and the lock.
    pub fn inventory(&self, root: &Path) -> BTreeSet<PathBuf> {
        self.whole
            .iter()
            .chain(&self.shared)
            .chain(&self.held)
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
        Self::laid_out(&self.relative(root), root)
    }

    fn laid_out(paths: &BTreeSet<String>, root: &Path) -> Result<String> {
        let mut text = serde_json::to_string_pretty(paths).map_err(|error| {
            crate::error::CoreError::JsonParse {
                path: root.join(INVENTORY),
                message: error.to_string(),
            }
        })?;
        text.push('\n');
        Ok(text)
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
/// In-place sources are out: they are executable source, not renders.
fn collect(
    state: &DesiredState,
    shims: &[ShimStanding],
    drift: &[super::DriftRow],
) -> GeneratedPaths {
    let mut generated = GeneratedPaths::default();
    for item in &state.items {
        if item.source_name == crate::manifest::INPLACE_SOURCE_NAME {
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
    generated.whole.extend(
        shims
            .iter()
            .filter(|shim| {
                matches!(
                    shim.state,
                    ShimState::InSync | ShimState::Missing | ShimState::Stale
                )
            })
            .map(|shim| shim.path.clone()),
    );
    generated
}

/// Collect what this pass renders and plan the inventory write for it.
/// The collection is handed back so the report can carry it to the commit
/// offer: one collection, so the inventory and the offer cannot disagree.
pub(super) fn plan(
    scope: &Scope,
    state: &DesiredState,
    shims: &[ShimStanding],
    drift: &[super::DriftRow],
    ops: &mut Vec<PlannedOp>,
) -> Result<GeneratedPaths> {
    let mut generated = collect(state, shims, drift);
    let Scope::Project { root } = scope else {
        return Ok(generated);
    };
    if !root.join(".git").exists() {
        return Ok(generated);
    }
    if !generated.held.is_empty() {
        let committed = crate::commit_offer::committed_inventory(root).map_err(|error| {
            crate::error::CoreError::GitFailed {
                command: "read committed generated inventory".to_owned(),
                stderr: if error.timed_out() {
                    "inventory read timed out".to_owned()
                } else {
                    error.said().join("\n")
                },
            }
        })?;
        generated.held.retain(|path| {
            path.strip_prefix(root)
                .ok()
                .is_some_and(|relative| committed.contains(&crate::paths::slashed(relative)))
        });
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

/// This repository's own committed inventory, held to what this pass
/// renders. Its own file: the check needs a message of its own.
#[cfg(all(test, unix))]
mod own_inventory;

/// The document's on-disk shape, which is what a merge reads.
#[cfg(test)]
mod tests;
