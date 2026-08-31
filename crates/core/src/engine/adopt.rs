use std::path::{Path, PathBuf};

use super::ops::manifest_for_mutation;
use crate::apply::{Description, Op, Plan, PlannedOp, Pre};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{self, INPLACE_SOURCE_NAME, ItemDecl, LOCAL_SOURCE_NAME};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::source::local_source_root;

mod capture;
mod held;
mod hooks;
mod inplace;
mod shared;
use capture::{Seen, capture_ops};
pub(super) use held::position;
use held::{Held, read_positions};
pub use held::{can_keep_all, can_keep_for};
use shared::{SharedTarget, shared_capture_ops, shared_target};
pub(super) use shared::{link_target, shared_tools};

/// Record an observed, unmanaged item into the manifest: its content moves
/// into the scope's local source (nothing is ever lost), the item is
/// declared from source `local`, and the original artifact goes to the
/// trash. A follow-up apply renders the managed replacement.
///
/// State machine: target-has-files → merge into declaration;
/// live symlink → adopt the *target's* content when it passes the shared-
/// target boundary (a skill folder the user linked several tools at), and
/// take every sibling link with it so the follow-up apply can restore the
/// sharing with kendex's copy as canonical; anything else a link points at
/// stays a conflict, never a clobber target; broken symlink → nothing to
/// adopt, the follow-up apply recreates from declaration.
/// The kinds adoption can take. A declaration built around content already
/// on disk needs somewhere in the local source to put that content, and
/// only these two have one — the same two the local-source match below
/// takes. Read wherever a refusal offers adoption as a way out, so no
/// message ever names an action that would error.
pub fn supports(kind: ItemKind) -> bool {
    matches!(kind, ItemKind::Agent | ItemKind::Skill) || hooks::supports(kind)
}

/// One plan for every tool the item is blocked for, because the item has
/// one copy: the local source holds a single capture and the declaration
/// names every tool reading it. A plan per tool would put each capture
/// over the last and pin the declaration to whichever ran first, leaving
/// the rest with files nothing manages.
pub fn adopt(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harnesses: &[HarnessId],
) -> Result<Plan> {
    // A plan entry, so the root is fixed here and nowhere downstream
    // (invariant 17). Without it this planner met two spellings of one
    // directory: positions come from the caller's scope while the tree a
    // link points at comes back resolved off disk, so on a checkout behind
    // a symlink — macOS fronts `/var` with `/private/var` — a plan trashed
    // a link under one name and renamed the tree under the other.
    let scope = &scope.canonical();
    // A hook is a script plus an entry in each tool's registry, not a file
    // at a position — it has its own planner rather than a case inside
    // this one.
    if hooks::supports(kind) {
        return hooks::adopt_hook(env, scope, name, harnesses);
    }
    usable(name)?;
    let mut manifest = manifest_for_mutation(env, scope)?;
    let Held {
        local_item,
        positions,
        seen,
    } = read_positions(env, scope, kind, name, harnesses)?;
    let Some((_, first_position)) = positions.first() else {
        return Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name: "no tool was named to keep it for".to_owned(),
        });
    };
    let Seen {
        shared, content, ..
    } = &seen;
    if shared.is_none() && content.is_empty() && !local_item.exists() {
        return Err(nothing_at(name, first_position));
    }

    let in_place = inplace::home(scope, kind, name).is_some();
    let mut ops = move_ops(kind, name, &local_item, first_position, in_place, &seen)?;
    // A shared folder is declared for every tool that was reading it, not
    // only the ones named — dropping the others is exactly the broken
    // sharing this path exists to avoid.
    let mut wanted: Vec<HarnessId> = harnesses.to_vec();
    if let Some((_, shared)) = &shared {
        for harness in &shared.harnesses {
            if !wanted.contains(harness) {
                wanted.push(*harness);
            }
        }
    }
    let already_declared = manifest.declared(kind).contains_key(name);
    let source = match in_place {
        true => INPLACE_SOURCE_NAME,
        false => LOCAL_SOURCE_NAME,
    };
    declare(&mut manifest, kind, name, wanted, already_declared, source);

    let manifest_path = manifest::manifest_path(env, scope);
    ops.push(PlannedOp {
        description: "declare the adopted item in kendex.toml".into(),
        op: Op::WriteManifest {
            pre: Pre::observed(&manifest_path)?,
            path: manifest_path,
            manifest: Box::new(manifest),
        },
    });
    Plan::landed(scope.clone(), ops)
}

/// Everything the move itself takes: the broken links cleared, and then
/// either the relocation into the shared tree or the capture into the local
/// source. The two are one choice, made once — `in_place` is the whole of
/// it, and every arm below reads it the same way.
fn move_ops(
    kind: ItemKind,
    name: &str,
    local_item: &Path,
    first_position: &Path,
    in_place: bool,
    seen: &Seen,
) -> Result<Vec<PlannedOp>> {
    let Seen {
        shared,
        content,
        broken,
    } = seen;
    let mut ops: Vec<PlannedOp> = broken
        .iter()
        .map(|(path, pre)| PlannedOp {
            description: Description::around("clear the broken link at ", ""),
            op: Op::Trash {
                absent_is_done: false,
                path: path.clone(),
                pre: pre.clone(),
            },
        })
        .collect();
    match (shared, in_place) {
        (Some((_, shared)), true) => ops.extend(inplace::relocate_ops(
            name,
            std::slice::from_ref(&shared.target),
            &shared.links,
            local_item,
        )?),
        (None, true) => {
            let held: Vec<PathBuf> = content.iter().map(|(_, path)| path.clone()).collect();
            if held.is_empty() {
                return Err(nothing_at(name, first_position));
            }
            ops.extend(inplace::relocate_ops(name, &held, &[], local_item)?);
        }
        (Some((_, shared)), false) => ops.extend(shared_capture_ops(name, shared, local_item)?),
        (None, false) => ops.extend(capture_ops(kind, name, content, local_item)?),
    }
    Ok(ops)
}

/// A name adoption may derive a path from. Every place it reads or writes
/// is this name joined onto a root, so an absolute or `..`-shaped one
/// leaves both the tool's directory and the local source, and the capture
/// moves — then trashes — a directory nobody named. It admits exactly the
/// names the rest of kendex installs, so an offer and the capture cannot
/// read different rules.
///
/// Three calls, three surfaces, not one guard thrice: `adopt` answers the
/// verb, ahead of the manifest read so a bad name is named as one rather
/// than as whatever else the scope is missing; `destination` answers
/// every path derived from a name, the planner's included; `position`
/// answers the exits a page draws.
fn usable(name: &str) -> Result<()> {
    match crate::names::item_problem(name) {
        Some(problem) => Err(unusable(name, problem)),
        None => Ok(()),
    }
}

/// Where the capture would land, or why it may not land there. A legal
/// name still spells a path, and the directories above the destination
/// are not the name's to vouch for — `slot_unreachable` holds what that
/// costs. One rule, asked by the verb before it plans a byte and by
/// `can_keep_for` before a surface draws a Keep, so no offer names an
/// action the capture would refuse.
pub(super) fn destination(env: &Env, scope: &Scope, kind: ItemKind, name: &str) -> Result<PathBuf> {
    // A project skill is its own source: its home is the tree the tools
    // already read, and there is no local source to reach into. The tree
    // still has to be one kendex can read back — bytes written past a
    // symlink are bytes the sealed reader refuses to look at, so the
    // declaration would name content nothing can resolve.
    usable(name)?;
    if let Some(home) = inplace::home(scope, kind, name) {
        return match inplace::unreachable(&home)? {
            Some(problem) => Err(unusable(name, problem)),
            None => Ok(home),
        };
    }
    let slot = local_item_path(env, scope, kind, name)?;
    match crate::source::slot_unreachable(env, scope, kind, name, &slot)? {
        Some(problem) => Err(unusable(name, problem)),
        None => Ok(slot),
    }
}

/// A refusal naming the name, shown: a name reaches a terminal as text,
/// so an escape sequence inside it is printed rather than run.
fn unusable(name: &str, problem: String) -> CoreError {
    CoreError::AdoptNameUnusable {
        name: crate::names::shown(name),
        problem,
    }
}

/// Where in the scope's local source the kept content lands, and the only
/// place the logical namespace survives: `plugin/item` is the nested
/// layout the local source lists back under that same name. Read wherever
/// a surface asks whether adoption could take a position, so the question
/// and the answer are never two different rules.
fn local_item_path(env: &Env, scope: &Scope, kind: ItemKind, name: &str) -> Result<PathBuf> {
    usable(name)?;
    if !matches!(kind, ItemKind::Skill | ItemKind::Agent) {
        return Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name: format!("adopt does not support {} yet", kind.name()),
        });
    }
    Ok(crate::source::local_slot(
        &local_source_root(env, scope),
        kind,
        name,
    ))
}

/// The positions the tools named hold nothing the capture could take.
/// Said once for both callers: the sentence is the same fact whether the
/// whole read came back empty or only the in-place arm found no content,
/// and one string is one place for the spelling to be right. The position
/// is text the reader is shown rather than a path going back to the
/// operating system, so `paths::slashed` spells it.
fn nothing_at(name: &str, position: &Path) -> CoreError {
    CoreError::ItemNotInSource {
        name: name.to_owned(),
        source_name: format!("nothing at {} to adopt", crate::paths::slashed(position)),
    }
}

pub(super) fn already_managed(name: &str, path: &Path) -> CoreError {
    CoreError::AlreadyManaged {
        name: name.to_owned(),
        path: crate::names::shown(&crate::paths::slashed(path)),
    }
}

/// Two tools hold different files under one name, and adoption has one
/// place to put them. Said as a choice only the reader can make, never
/// settled by picking one.
fn copies_differ(name: &str, first: HarnessId, second: HarnessId) -> CoreError {
    CoreError::AdoptedCopiesDiffer {
        name: name.to_owned(),
        first: first.display_name().to_owned(),
        second: second.display_name().to_owned(),
    }
}

// Writing the kept item into the manifest: which tools it names, and
// which of the declaration's old facts no longer hold once its source is
// the local one.

/// Write the item into the manifest, bound to the tools that had it. Only
/// when the `[install]` defaults name exactly that set may the list be left
/// off: a wider default would install the item for tools the user never
/// gave it to.
fn declare(
    manifest: &mut manifest::Manifest,
    kind: ItemKind,
    name: &str,
    wanted: Vec<HarnessId>,
    already_declared: bool,
    source: &str,
) {
    let defaults_match = {
        let defaults: std::collections::BTreeSet<&HarnessId> =
            manifest.install.harnesses.iter().collect();
        wanted
            .iter()
            .collect::<std::collections::BTreeSet<&HarnessId>>()
            == defaults
    };
    let decl = manifest
        .declared_mut(kind)
        .entry(name.to_owned())
        .or_insert_with(|| ItemDecl::from_source(source));
    decl.source = source.to_owned();
    // A revision names a commit in the source it came from. Carried onto
    // the local source, which has no revisions, the next plan fails and the
    // scope cannot be planned at all until somebody edits kendex.toml — and
    // the capture has already run by then.
    decl.rev = None;
    match &mut decl.harnesses {
        // A list already there is extended, never replaced: the tools it
        // names still have the item, and pinning it to the ones being kept
        // now would leave the rest with files nothing manages.
        Some(listed) => {
            for harness in wanted {
                if !listed.contains(&harness) {
                    listed.push(harness);
                }
            }
        }
        // A declaration that was already here and left the tools to the
        // [install] defaults keeps them. Pinning it to what was observed
        // would narrow it — a tool that had nothing at its place this pass
        // would stop getting the item at all, which is not what keeping
        // files was asked to do.
        None if !defaults_match && !already_declared => decl.harnesses = Some(wanted),
        None => {}
    }
}

#[cfg(test)]
mod tests;
