//! Whether one captured file can answer for every tool the declaration
//! targets.
//!
//! A fork beside writes one source form into the local source, and every
//! targeted tool renders from it afterwards. Before it, each renders from
//! its own installed revision, and those can differ — the lock records one
//! per tool. A revision the capture did not read can state tools its own
//! does not, so what that tool's rendering restricts is unreadable from the
//! captured file and its loss would pass unseen. Reading each tool's own
//! revision instead would mean opening the catalog at every one of them,
//! which is the thing the capture does not do; refusing keeps that boundary
//! and fails closed.

use crate::engine::desired::target_harnesses;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{ItemDecl, Manifest};
use crate::model::{ItemKind, Scope};

/// Refuse a capture whose targeted tools are not all installed from the
/// revision it was read at. `read_at` is that revision.
///
/// One rule with two reasons: a tool recorded at another revision, and a
/// tool whose revision is not recorded at all. Both leave the file unable
/// to answer for it, so neither is agreement.
pub(super) fn one_revision(
    env: &Env,
    scope: &Scope,
    after: &Manifest,
    decl: &ItemDecl,
    name: &str,
    read_at: Option<&str>,
) -> Result<()> {
    let lock = crate::lock::load(&crate::lock::lock_path(env, scope))?;
    let mut elsewhere: Vec<String> = Vec::new();
    for harness in target_harnesses(decl, after, ItemKind::Agent, scope) {
        // No lock entry is no installation on this tool: nothing was
        // rendered there, so there is no artifact whose restrictions could
        // be lost. An entry holding no revision is the opposite case —
        // something is installed and what it was rendered from cannot be
        // established, which is not the same answer as rendering from the
        // same revision.
        let Some(entry) = lock
            .entries
            .get(&crate::lock::entry_key(ItemKind::Agent, name, harness))
        else {
            continue;
        };
        // Compared as written, absence included: a source whose revisions
        // are not commits records none for anybody, and every tool reading
        // that one mutable directory does agree. One recorded and one
        // absent is a disagreement like any other.
        let at = entry.source_commit.as_deref();
        if at == read_at {
            continue;
        }
        elsewhere.push(match at {
            Some(commit) => format!("{} from {commit}", harness.display_name()),
            None => format!(
                "{}, whose revision the lock does not record",
                harness.display_name()
            ),
        });
    }
    if elsewhere.is_empty() {
        return Ok(());
    }
    Err(CoreError::ForkWidensAccess {
        name: crate::names::shown(name),
        problem: format!(
            "the tool settings {} state{}: {} — this copy is taken from {}, and a published file at one revision does not say what another one restricts. Refresh so every tool sits at the same revision, then keep it",
            match elsewhere.len() {
                1 => "the rendering it leaves behind".to_owned(),
                n => format!("the {n} renderings it leaves behind"),
            },
            if elsewhere.len() == 1 { "s" } else { "" },
            elsewhere.join(", "),
            read_at.unwrap_or("a revision nothing recorded")
        ),
    })
}
