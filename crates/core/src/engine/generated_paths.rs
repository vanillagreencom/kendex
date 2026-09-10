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

/// The two files every render in a project depends on: the inventory that
/// records which paths kendex owns here, and the manifest that declares
/// what is installed. A commit that adds or removes a render without them
/// is one the next apply undoes.
pub fn companions(root: &Path) -> [PathBuf; 2] {
    [
        root.join(INVENTORY),
        root.join(crate::manifest::MANIFEST_FILE),
    ]
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

    /// The files kendex owns whole, the inventory file among them — what
    /// the commit offer covers. The inventory is kendex's own file end to
    /// end, so it is committed with the renders it records.
    ///
    /// The project's manifest is here for the same reason and no other: a
    /// commit carrying a render whose declaration stays behind is a
    /// checkout the next `kendex apply` sweeps the render back out of. It
    /// is kendex's own format end to end — every key in it is an
    /// instruction to kendex — which a shared configuration file is not.
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
    let relative: BTreeSet<String> = generated
        .inventory(root)
        .iter()
        .filter_map(|path| path.strip_prefix(root).ok().map(crate::paths::slashed))
        .collect();
    let mut text =
        serde_json::to_string(&relative).map_err(|error| crate::error::CoreError::JsonParse {
            path: path.clone(),
            message: error.to_string(),
        })?;
    text.push('\n');
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
