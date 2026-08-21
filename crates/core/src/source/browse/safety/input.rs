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
/// past a tool's cap is split into `references/`, where the rules read it
/// one weight lower.
///
/// A package installs to several tools and each renders it its own way, so
/// there is no one tree to score — and the one a preview must not show is a
/// tree nobody installs. Splitting only ever lowers what a line weighs, so
/// the harshest of the renderings is the one that splits least: no split at
/// all where any tool this item goes to has no cap, and otherwise the
/// largest cap among them. A preview that took the smallest instead showed
/// the mildest rendering and promised better than the install delivers —
/// Claude has no cap, so Claude beside Codex read as a warning while the
/// install Claude got was held back.
///
/// The project's own instructions are deliberately *not* folded in — the
/// page says so — because a preview is about the package, and the gate
/// stays the authority on what the combination scores.
fn installs_as(
    browsed: &Browsed,
    kind: ItemKind,
    name: &str,
    path: &std::path::Path,
) -> Result<Vec<(PathBuf, Vec<u8>)>> {
    let files = crate::render::skill::render_authored(&browsed.sealed, path)?;
    let caps: Vec<Option<usize>> = installs_to(browsed, kind, name)
        .into_iter()
        .map(|harness| crate::harness::format_caps(harness).skill_body_max_bytes)
        .collect();
    let Some(cap) = caps
        .iter()
        .copied()
        .max()
        .flatten()
        .filter(|_| caps.iter().all(Option::is_some))
    else {
        return Ok(files);
    };
    // A refusal is the real rendering's to report; the files it hands back
    // are what there is to score either way.
    Ok(crate::render::split::enforce_body_cap(files, cap, None).files)
}

/// Which tools this item would install to, through the plan's own
/// derivation over the declaration it would install under.
///
/// Both halves matter and neither is spelled here. Reading only the scope
/// default models the wrong set for every item that names its own tools;
/// keeping a tool that cannot take the kind in this scope models a
/// rendering nobody installs — a requested Cursor has no body cap, so it
/// would keep a long skill unsplit and hold the page back while the plan
/// drops Cursor and splits for Codex. `target_harnesses` is what the plan
/// asks, so it is what this asks.
fn installs_to(browsed: &Browsed, kind: ItemKind, name: &str) -> Vec<crate::model::HarnessId> {
    let under = decl_for(browsed, kind, name);
    crate::engine::harnesses_for(
        under.as_ref().and_then(|decl| decl.harnesses.as_deref()),
        &browsed.manifest,
        kind,
        &browsed.scope,
    )
}

/// The declaration this item would install under: its own where the project
/// declared it by name, otherwise the one belonging to whatever put it
/// there. `None` where nothing here has asked for it at all.
///
/// A bundle member has no declaration under its own name, and a lookup that
/// assumes one falls through to the scope's defaults — a bundle targeting
/// one tool then previews a rendering that tool never gets. What a member
/// installs under is [`crate::engine::bundles::member_decl`], the same
/// answer the plan builds from.
///
/// Only a bundle installed from this catalog can be what put it here: a
/// set's members are its own catalog's items, so a bare name in another
/// catalog's bundle names something else.
fn decl_for(browsed: &Browsed, kind: ItemKind, name: &str) -> Option<crate::manifest::ItemDecl> {
    if let Some(own) = browsed.manifest.declared(kind).get(name) {
        return Some(own.clone());
    }
    browsed
        .manifest
        .bundles
        .iter()
        .filter(|(_, decl)| browsed.owned_here(&decl.source))
        .find(|(bundle, _)| carries(browsed, bundle, kind, name))
        .map(|(_, decl)| crate::engine::bundles::member_decl(decl))
}

/// Whether one of this catalog's sets carries this item.
fn carries(browsed: &Browsed, bundle: &str, kind: ItemKind, name: &str) -> bool {
    crate::source::bundles::find(&browsed.sealed, &browsed.config, bundle)
        .ok()
        .flatten()
        .is_some_and(|set| {
            set.members
                .iter()
                .any(|member| member.kind == kind && member.name == name)
        })
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
            files: crate::quality::observe::tree_files_from_bytes(&installs_as(
                browsed, kind, name, path,
            )?),
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
