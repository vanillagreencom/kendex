//! The manifest write a plan carries, and whether it already carries one.
//! A plan writes the manifest at most once: the write binds to the bytes
//! it read, so a second write's precondition is bytes the first one has
//! already replaced, and it could never run.

use crate::apply::{Op, PlannedOp};
use crate::env::Env;
use crate::error::Result;
use crate::manifest::{self, Manifest};
use crate::model::Scope;

use super::PlanOptions;
use super::desired;
use super::scope_writes::{plan_repo_move_write, plan_schema_upgrade};

/// The plan's one manifest write, when anything needs it: skills an agent
/// gained upstream or a review of findings this run was asked to record
/// take the full serialized write — or, with neither, the repository move
/// or the schema upgrade lands as a surgical text edit that keeps the
/// user's comments and formatting. One write whatever put it there: a
/// second manifest write could never run, its precondition binds to the
/// bytes the first one replaces. The description names the biggest cause;
/// the rest ride along in the same bytes.
pub(super) fn plan_manifest_write(
    env: &Env,
    scope: &Scope,
    repo_moved: bool,
    manifest: &Manifest,
    state: &desired::DesiredState,
    options: &PlanOptions,
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    let Some(update) = &state.manifest_update else {
        if repo_moved {
            return plan_repo_move_write(env, scope, manifest, options, ops);
        }
        if manifest.schema < manifest::MANIFEST_SCHEMA {
            plan_schema_upgrade(env, scope, manifest, options, ops)?;
        }
        return Ok(());
    };
    let path = manifest::manifest_path(env, scope);
    let pre = options.manifest_pre(&path)?;
    let mut updated = update.clone();
    updated.schema = manifest::MANIFEST_SCHEMA;
    let granted = updated.safety_overrides != manifest.safety_overrides;
    ops.push(PlannedOp {
        description: match (repo_moved, granted) {
            (true, _) => crate::repo_move::MOVE_DESCRIPTION.into(),
            (false, true) => "Update kendex.toml with the safety findings you accepted".into(),
            (false, false) => "Add new catalog skills to kendex.toml".into(),
        },
        op: Op::WriteManifest {
            pre,
            path,
            manifest: Box::new(updated),
        },
    });
    Ok(())
}

/// Whether a plan already persists the manifest — the full serialized
/// write, or the repository move's surgical text edit. A caller about to
/// insert its own save must count both: a second write to the same file
/// binds to bytes the first one replaces and could never run.
pub fn persists_manifest(ops: &[PlannedOp]) -> bool {
    ops.iter().any(|op| {
        matches!(op.op, Op::WriteManifest { .. })
            || (op.description == crate::repo_move::MOVE_DESCRIPTION
                && matches!(op.op, Op::WriteFile { .. }))
    })
}
