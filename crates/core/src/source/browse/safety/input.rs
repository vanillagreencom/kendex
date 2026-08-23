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
/// marked block is the project's to write and never installs. Every tool
/// reads the same rendering, so there is one tree to score.
///
/// The project's own instructions are deliberately *not* folded in — the
/// page says so — because a preview is about the package, and the gate
/// stays the authority on what the combination scores.
fn installs_as(browsed: &Browsed, path: &std::path::Path) -> Result<Vec<(PathBuf, Vec<u8>)>> {
    crate::render::skill::render_authored(&browsed.sealed, path)
}

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
        // Through the same constructor the install gate reads a tree with,
        // over the tree this project would install — the rendering every
        // tool gets — so preview and gate cannot disagree about one package.
        ItemKind::Skill => {
            crate::quality::observe::tree_content_from_bytes(&installs_as(browsed, path)?)
        }
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
