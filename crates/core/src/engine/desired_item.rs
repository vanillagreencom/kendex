//! One declared item becoming the installations a plan would write.
//!
//! The dispatch by kind, and the two things that can be said about a
//! declaration before any renderer sees it.

use crate::error::Result;
use crate::manifest::{ItemDecl, Manifest};
use crate::model::ItemKind;

use super::desired::{DesiredState, ItemCtx};
use super::desired_skill::desired_skill;
use super::{desired_agent, desired_kinds};

/// Turn one declared item into its desired installations.
///
/// One hostile item must not take the whole scope down: a refused catalog
/// read becomes an unreadable note, and what it already installed stays out
/// of the orphan sweep. "unreadable" is the phrase verify keys on — a
/// refused item must fail verification, never print a green tick.
pub(super) fn build(
    kind: ItemKind,
    ctx: &ItemCtx,
    state: &mut DesiredState,
    updated_manifest: &mut Manifest,
    manifest_changed: &mut bool,
) -> Result<()> {
    let outcome = match kind {
        ItemKind::Skill => desired_skill(ctx, state),
        ItemKind::Agent => {
            desired_agent::desired_agent(ctx, state, updated_manifest, manifest_changed)
        }
        ItemKind::Hook => desired_kinds::desired_hook(ctx, state),
        ItemKind::Command => super::desired_command::desired_command(ctx, state),
        ItemKind::McpServer => super::desired_mcp::desired_mcp(ctx, state),
        _ => Ok(()),
    };
    match outcome {
        Ok(()) => Ok(()),
        Err(crate::error::CoreError::SourceEscape { path, reason }) => {
            let name = ctx.name;
            state.unreadable(
                kind,
                name,
                format!(
                    "{name}: unreadable — refused catalog read: {reason} ({})",
                    path.display()
                ),
            );
            Ok(())
        }
        Err(other) => Err(other),
    }
}

/// Every tool this is declared for is one that holds no such kind here.
/// Nothing installs, and silence would read as success.
pub(super) fn no_harness_note(
    kind: ItemKind,
    name: &str,
    decl: &ItemDecl,
    manifest: &Manifest,
    state: &mut DesiredState,
) {
    let asked: Vec<&str> = decl
        .harnesses
        .as_ref()
        .unwrap_or(&manifest.install.harnesses)
        .iter()
        .map(|harness| harness.display_name())
        .collect();
    state.notes.push(format!(
        "{} {name}: {} cannot hold one at this scope — nothing was installed",
        kind.name(),
        asked.join(", ")
    ));
}
