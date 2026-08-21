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
    Ok(
        crate::render::split::enforce_body_cap(crate::render::skill::Rendered::plain(files), cap)
            .rendered
            .into_files(),
    )
}

/// Which tools this item would install to, through the plan's own
/// derivation over every declaration that asks for it.
///
/// Both halves matter and neither is spelled here. Reading only the scope
/// default models the wrong set for every item that names its own tools;
/// keeping a tool that cannot take the kind in this scope models a
/// rendering nobody installs — a requested Cursor has no body cap, so it
/// would keep a long skill unsplit and hold the page back while the plan
/// drops Cursor and splits for Codex. `harnesses_for` is what the plan
/// asks, so it is what this asks.
///
/// Every declaration and not one of them: an item can be declared by name
/// and carried by a set, or carried by two sets aiming at different tools,
/// and the plan lands it on the union of what they ask for. Picking one
/// previews a rendering some of its installations never get, and the
/// harshest-rendering rule below is only as good as the set it runs over.
fn installs_to(browsed: &Browsed, kind: ItemKind, name: &str) -> Vec<crate::model::HarnessId> {
    let asked = asked_by(browsed, kind, name);
    let tools = |harnesses: Option<&[crate::model::HarnessId]>| {
        crate::engine::harnesses_for(harnesses, &browsed.manifest, kind, &browsed.scope)
    };
    // Nothing here asks for it yet, so what is being asked is which tools
    // this scope would put it on.
    if asked.is_empty() {
        return tools(None);
    }
    asked
        .iter()
        .flat_map(|decl| tools(decl.harnesses.as_deref()))
        .collect::<std::collections::BTreeSet<_>>()
        .into_iter()
        .collect()
}

/// Every declaration that would install this item.
///
/// There are three ways an installation comes to exist, and the plan writes
/// each of them down as a [`crate::lock::Reason`]: the user asked for it,
/// a set carries it, or a skill requires it. A derived installation has no
/// declaration under its own name, so a lookup that wants one falls through
/// to the scope's defaults — and a set or a parent targeting one tool then
/// previews a rendering that tool never gets.
///
/// `Requested` is the item's own declaration. `MemberOf` is
/// [`crate::engine::bundles::member_decl`], what the plan builds a member
/// from. `RequiredBy` is the parent's, since a dependency's own declaration
/// names no tools and the plan installs it on the ones its parent landed
/// on; a dependency of a dependency inherits the same way, so the walk
/// carries whatever asked for the root down to it.
///
/// Only what this catalog holds can be any of them: a set's members and a
/// skill's dependencies are its own catalog's items, so a bare name in
/// another catalog names something else — and a declaration of the same
/// kind and name from another source is a name collision, never a request
/// for this package. Every one of the three is filtered the same way,
/// because two of three having the guard is how the third went unnoticed.
fn asked_by(browsed: &Browsed, kind: ItemKind, name: &str) -> Vec<crate::manifest::ItemDecl> {
    let own = browsed
        .manifest
        .declared(kind)
        .get(name)
        .filter(|decl| browsed.owned_here(&decl.source))
        .cloned();
    let sets = browsed
        .manifest
        .bundles
        .iter()
        .filter(|(_, decl)| browsed.owned_here(&decl.source))
        .filter(|(bundle, _)| carries(browsed, bundle, kind, name))
        .map(|(_, decl)| crate::engine::bundles::member_decl(decl));
    own.into_iter()
        .chain(sets)
        .chain(required_by(browsed, kind, name))
        .collect()
}

/// The declarations behind every skill that would bring this one in as a
/// dependency, walked from the ones this project actually asks for.
///
/// Only skills require anything, and only of skills. The walk starts at
/// what is asked for directly — by name or through a set — and follows the
/// same lists the plan follows, so a dependency two levels down still ends
/// up under the tools that asked for the root.
fn required_by(browsed: &Browsed, kind: ItemKind, name: &str) -> Vec<crate::manifest::ItemDecl> {
    if kind != ItemKind::Skill {
        return Vec::new();
    }
    let mut found = Vec::new();
    for root in asked_directly(browsed) {
        let mut walked = std::collections::BTreeSet::new();
        let mut queue = vec![root.0.clone()];
        while let Some(parent) = queue.pop() {
            if !walked.insert(parent.clone()) {
                continue;
            }
            for dep in requires(browsed, &parent) {
                if dep == name {
                    found.push(root.1.clone());
                }
                queue.push(dep);
            }
        }
    }
    found
}

/// The skills this project asks for from this catalog by name or through a
/// set, each with the declaration it installs under.
fn asked_directly(browsed: &Browsed) -> Vec<(String, crate::manifest::ItemDecl)> {
    let own = browsed
        .manifest
        .declared(ItemKind::Skill)
        .iter()
        .filter(|(_, decl)| browsed.owned_here(&decl.source))
        .map(|(name, decl)| (name.clone(), decl.clone()));
    let carried = browsed
        .manifest
        .bundles
        .iter()
        .filter(|(_, decl)| browsed.owned_here(&decl.source))
        .flat_map(|(bundle, decl)| {
            members(browsed, bundle)
                .into_iter()
                .filter(|member| member.kind == ItemKind::Skill)
                .map(move |member| (member.name, crate::engine::bundles::member_decl(decl)))
        });
    own.chain(carried).collect()
}

/// The skills one skill of this catalog requires, as the plan reads them:
/// the required ones plus the optional ones this project chose.
fn requires(browsed: &Browsed, parent: &str) -> Vec<String> {
    let Some(dir) =
        crate::source::find_item(&browsed.sealed, &browsed.config, ItemKind::Skill, parent)
    else {
        return Vec::new();
    };
    let Ok(declared) = crate::engine::deps::declared_dependencies(&browsed.sealed, &dir) else {
        return Vec::new();
    };
    let chosen = browsed
        .manifest
        .optional_dependencies
        .get(parent)
        .cloned()
        .unwrap_or_default();
    declared
        .required
        .into_iter()
        .chain(declared.optional.into_iter().filter(|o| chosen.contains(o)))
        .collect()
}

/// Whether one of this catalog's sets carries this item.
fn carries(browsed: &Browsed, bundle: &str, kind: ItemKind, name: &str) -> bool {
    members(browsed, bundle)
        .iter()
        .any(|member| member.kind == kind && member.name == name)
}

/// What one of this catalog's sets carries.
fn members(browsed: &Browsed, bundle: &str) -> Vec<crate::source::bundles::BundleMember> {
    crate::source::bundles::find(&browsed.sealed, &browsed.config, bundle)
        .ok()
        .flatten()
        .map(|set| set.members)
        .unwrap_or_default()
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
