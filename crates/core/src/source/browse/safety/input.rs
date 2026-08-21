//! What a preview gives the safety rules to read.
//!
//! Split out of `safety.rs`. One question, and the whole reason a preview
//! is worth showing: it has to be the reading the install gate does, over
//! the content the install would write.

use std::path::PathBuf;

use crate::error::Result;
use crate::model::ItemKind;
use crate::quality::{AuditInput, Content};

use super::super::Browsed;
use super::Item;

/// The tree this project would install, from the publisher's own bytes: a
/// marked block is the project's to write and never installs, and a body
/// past the tightest cap any harness here enforces is split into
/// `references/`, where the rules read it one weight lower. Scoring the
/// catalog's unsplit source instead reads that line at full weight, which
/// is how a package reads held back whose install is not.
///
/// The project's own instructions are deliberately *not* folded in — the
/// page says so — because a preview is about the package, and the gate
/// stays the authority on what the combination scores.
fn installs_as(browsed: &Browsed, path: &std::path::Path) -> Result<Vec<(PathBuf, Vec<u8>)>> {
    let files = crate::render::skill::render_authored(&browsed.sealed, path)?;
    let Some(cap) = browsed
        .manifest
        .install
        .harnesses
        .iter()
        .filter_map(|harness| crate::harness::format_caps(*harness).skill_body_max_bytes)
        .min()
    else {
        return Ok(files);
    };
    // A refusal is the real rendering's to report; the files it hands back
    // are what there is to score either way.
    Ok(crate::render::split::enforce_body_cap(files, cap).files)
}

/// The same typed input `check --catalog` audits: a skill's whole tree,
/// one document for every file-per-item kind.
pub(super) fn input_for(
    browsed: &Browsed,
    kind: ItemKind,
    name: &str,
    item: &Item,
) -> Result<AuditInput> {
    let path = &item.path;
    let location = path
        .strip_prefix(browsed.sealed.root())
        .unwrap_or(path)
        .display()
        .to_string();
    let content = match kind {
        // Through the same budgeted constructor the install gate reads a
        // tree with, over the tree this project would install rather than
        // the one the catalog holds. A preview that read further, or that
        // read the source unsplit, would score findings the gate never sees
        // at weights it never gives them — the two disagreeing about one
        // package, which is the whole thing a preview is for.
        ItemKind::Skill => Content::SkillTree {
            files: crate::quality::observe::tree_files_from_bytes(&installs_as(browsed, path)?),
        },
        // A hook's script is what the harness runs; browse scores it as a hook
        // so the rules that read event/command/script fire here too, not only
        // at the install gate. The MCP declaration and command bodies read as
        // their file text; the install gate stays the authoritative verdict.
        ItemKind::Hook => Content::Hook {
            event: String::new(),
            matcher: None,
            command: location.clone(),
            script: Some(browsed.sealed.read_to_string(path)?),
        },
        _ => Content::Document {
            text: browsed.sealed.read_to_string(path)?,
        },
    };
    Ok(AuditInput {
        kind,
        name: name.to_owned(),
        harness: None,
        location,
        content,
    })
}
