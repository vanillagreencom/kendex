//! Committed CI inventory derived from the artifacts the engine renders.
//! Carrier packages and in-place sources are executable source, not renders.

use std::collections::BTreeSet;

use crate::apply::{Op, PlannedOp, Pre};
use crate::error::Result;
use crate::model::Scope;

use super::desired::{Artifact, DesiredState};
use super::instruction_shims::{ShimStanding, ShimState};

pub(super) fn plan(
    scope: &Scope,
    state: &DesiredState,
    shims: &[ShimStanding],
    drift: &[super::DriftRow],
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    let Scope::Project { root } = scope else {
        return Ok(());
    };
    if !root.join(".git").exists() {
        return Ok(());
    }
    let mut paths = BTreeSet::new();
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
                paths.insert(path.clone());
            }
            Artifact::Tree {
                canonical,
                files,
                link,
            } => {
                paths.extend(files.iter().map(|(path, _)| canonical.join(path)));
                paths.extend(link.iter().cloned());
            }
            Artifact::Registration { script, edits } => {
                paths.extend(script.iter().map(|(path, _)| path.clone()));
                paths.extend(edits.iter().map(|(path, _)| path.clone()));
            }
        }
    }
    paths.extend(
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
    let path = root.join(".kendex-generated.json");
    if paths.is_empty() && !path.exists() {
        return Ok(());
    }
    paths.insert(path.clone());
    let relative: BTreeSet<String> = paths
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
        return Ok(());
    }
    ops.push(PlannedOp {
        description: "Record generated paths for CI".to_owned().into(),
        op: Op::WriteFile {
            pre: Pre::observed(&path)?,
            path,
            bytes: text.into_bytes(),
        },
    });
    Ok(())
}
