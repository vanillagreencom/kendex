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

use super::desired::{Artifact, DesiredState};
use super::instruction_shims::{ShimStanding, ShimState};

/// The name of the inventory CI reads, at a project root.
pub const INVENTORY: &str = ".kendex-generated.json";

/// The file that travels with a commit that adds or takes away a render:
/// the inventory recording which paths kendex owns here.
///
/// Not because a render needs it to stand. The engine never reads it back —
/// it writes it for CI — and a later apply judges the tree by the manifest
/// and the lock. It travels because the commit offer itself reads the
/// committed copy: `crate::commit_offer` asks `HEAD`'s inventory whether a
/// path that is deleted and gone from the render set was one kendex wrote,
/// which is how a sweep's removal is told from the person's own deletion. A
/// commit that adds or takes away a render without it leaves that read
/// answering about a tree the commit no longer holds.
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
pub fn companions(root: &Path) -> [PathBuf; 1] {
    [root.join(INVENTORY)]
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
}

impl GeneratedPaths {
    /// Nothing rendered at all, in either group.
    pub fn is_empty(&self) -> bool {
        self.whole.is_empty() && self.shared.is_empty()
    }

    /// Every path the inventory records: both groups, plus the inventory
    /// file itself. CI reads this to know every path kendex touches.
    pub fn inventory(&self, root: &Path) -> BTreeSet<PathBuf> {
        self.whole
            .iter()
            .chain(&self.shared)
            .cloned()
            .chain(std::iter::once(root.join(INVENTORY)))
            .collect()
    }

    /// Every inventory path as the document spells it: relative to the
    /// root, slashed, and sorted by the set it comes out of.
    ///
    /// This is the one derivation of that set. The write reaches it through
    /// [`GeneratedPaths::document`] and `own_inventory.rs` reads it directly,
    /// so neither decides what a render is a second time.
    fn relative(&self, root: &Path) -> BTreeSet<String> {
        self.inventory(root)
            .iter()
            .filter_map(|path| path.strip_prefix(root).ok().map(crate::paths::slashed))
            .collect()
    }

    /// The inventory document, exactly as the write below lays it down: the
    /// write's serialization of [`GeneratedPaths::relative`], and nothing
    /// besides.
    ///
    /// A reader holds the committed copy to that set rather than to these
    /// bytes — `own_inventory.rs` parses the JSON back into a set, as
    /// commit-guards' `generated-paths.sh` does — so the order and the
    /// spacing are this function's alone and no reader depends on them.
    fn document(&self, root: &Path) -> Result<String> {
        let mut text = serde_json::to_string(&self.relative(root)).map_err(|error| {
            crate::error::CoreError::JsonParse {
                path: root.join(INVENTORY),
                message: error.to_string(),
            }
        })?;
        text.push('\n');
        Ok(text)
    }

    /// The files kendex owns whole, the inventory file among them — what
    /// the commit offer covers. The inventory is kendex's own file end to
    /// end, so a commit may take it; [`companions`] says why one that adds
    /// or takes away a render does.
    ///
    /// Owning the FORMAT is not owning the bytes, so the project's manifest
    /// is not here: `crate::manifest::fold` exists because kendex edits the
    /// keys it holds and leaves the rest of that document alone. This set is
    /// what a restore writes over, and nothing kendex only edits keys in may
    /// be written over whole.
    pub fn owned(&self, root: &Path) -> BTreeSet<PathBuf> {
        self.whole.iter().cloned().chain(companions(root)).collect()
    }
}

/// The paths this pass renders, by group.
///
/// In-place sources and items whose drift row is `Conflict` or `Unmanaged`
/// are out: kendex writes nothing for them, so neither the inventory nor
/// the offer may claim them.
fn collect(
    state: &DesiredState,
    shims: &[ShimStanding],
    drift: &[super::DriftRow],
) -> GeneratedPaths {
    let mut generated = GeneratedPaths::default();
    for item in &state.items {
        if item.source_name == crate::manifest::INPLACE_SOURCE_NAME
            || drift.iter().any(|row| {
                row.kind == item.kind
                    && row.name == item.name
                    && row.harness == item.harness
                    && matches!(
                        row.state,
                        super::DriftState::Conflict | super::DriftState::Unmanaged
                    )
            })
        {
            continue;
        }
        match &item.artifact {
            Artifact::File { path, .. } => {
                generated.whole.insert(path.clone());
            }
            Artifact::Tree {
                canonical,
                files,
                link,
            } => {
                generated
                    .whole
                    .extend(files.iter().map(|(path, _)| canonical.join(path)));
                generated.whole.extend(link.iter().cloned());
            }
            Artifact::Registration { script, edits } => {
                generated
                    .whole
                    .extend(script.iter().map(|(path, _)| path.clone()));
                generated
                    .shared
                    .extend(edits.iter().map(|(path, _)| path.clone()));
            }
        }
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
    let generated = collect(state, shims, drift);
    let Scope::Project { root } = scope else {
        return Ok(generated);
    };
    if !root.join(".git").exists() {
        return Ok(generated);
    }
    let path = root.join(INVENTORY);
    // A project that renders nothing gets no inventory, and one that
    // already has one keeps it current even when it empties out.
    if generated.is_empty() && !path.exists() {
        return Ok(generated);
    }
    let text = generated.document(root)?;
    if crate::fs::read_if_exists(&path)?.as_deref() == Some(&text) {
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
