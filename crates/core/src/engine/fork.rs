//! Keeping a user's edits: the edited installation becomes a local package
//! under the same name. Fork is adopt with provenance — the bytes move into
//! the scope's local source, the declaration flips to `local`, and the
//! manifest records what it replaced. The name never changes, so nothing
//! that depends on it breaks.

use std::path::PathBuf;

use super::desired::native_dir;
use super::ops::manifest_for_mutation;
use crate::apply::{Op, Plan, PlannedOp, Pre};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{self, INPLACE_SOURCE_NAME, LOCAL_SOURCE_NAME};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::source::local_source_root;

mod agent;
mod beside;
mod forkable;
mod provenance;
mod rename;
mod revision;
mod skill_tree;
mod stated;
mod vacant;
use agent::capture_agent;
pub use beside::fork_beside;
use forkable::{ambiguous_skill_tree, forkable_kind, source_form, unsupported_kind};
pub use forkable::{forkable_harness, forkable_rendering};
use provenance::{installed_commit, provenance};
pub use rename::rename_fork;
pub(crate) use skill_tree::skill_content_path;
use vacant::vacant_name;

/// Turn one edited installation into a local fork. The harness names which
/// installation's bytes are captured — an agent renders per tool, and the
/// edit lives in exactly one rendering. Skills capture the canonical tree,
/// the one place every tool's link resolves to.
///
/// The plan: capture the edited bytes into the local source (a previous
/// local copy goes to the trash first, never overwritten), trash the edited
/// artifact so the follow-up apply re-renders it from the fork, and write
/// the manifest — source flipped to `local`, any hold cleared (a fork of a
/// local directory has no revisions), provenance recorded.
pub fn fork(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
) -> Result<Plan> {
    // The same first question its two sibling verbs ask, so all three
    // answer a kind they cannot fork with the same words.
    forkable_kind(kind, name)?;
    let mut manifest = manifest_for_mutation(env, scope)?;
    let Some(decl) = manifest.declared(kind).get(name).cloned() else {
        return Err(CoreError::NotDeclared {
            kind,
            name: name.to_owned(),
        });
    };
    if decl.source == LOCAL_SOURCE_NAME || decl.source == INPLACE_SOURCE_NAME {
        return Err(CoreError::AlreadyOwn {
            name: name.to_owned(),
            origin: decl.source.clone(),
        });
    }
    let (edited, captured) = capture_rendering(env, scope, kind, name, harness, &manifest, &decl)?;
    let mut ops = capture_ops(env, scope, kind, name, &edited, captured.files)?;
    let provenance = provenance(env, scope, kind, name, harness, &manifest, &decl)?;
    // The catalog's mapping tables shaped the rendering and the fork stops
    // reading them, so their effective values move into the manifest or the
    // very next apply renders a different agent under the same name.
    if let Some(carry) = captured.carry {
        carry.apply(&mut manifest, name);
    }
    let entry = manifest
        .declared_mut(kind)
        .get_mut(name)
        .unwrap_or_else(|| unreachable!("declared above"));
    entry.source = LOCAL_SOURCE_NAME.to_owned();
    entry.rev = None;
    manifest
        .forks
        .entry(kind)
        .or_default()
        .insert(name.to_owned(), provenance);

    let manifest_path = manifest::manifest_path(env, scope);
    ops.push(PlannedOp {
        description: format!("record the fork of {name} in kendex.toml").into(),
        op: Op::WriteManifest {
            pre: Pre::observed(&manifest_path)?,
            path: manifest_path,
            manifest: Box::new(manifest),
        },
    });
    Plan::landed(scope.clone(), ops)
}

/// The file or tree holding this rendering's edited bytes. Skills capture
/// the tree every tool's link resolves to; an agent only from a tool whose
/// rendering round-trips through the source parser.
fn edited_rendering(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
) -> Result<PathBuf> {
    let edited = match kind {
        ItemKind::Skill => {
            let tree = skill_content_path(env, scope, name, harness).ok_or({
                CoreError::ItemNotFound {
                    kind,
                    name: name.to_owned(),
                    harness,
                }
            })?;
            if ambiguous_skill_tree(&tree) {
                return Err(CoreError::ForkAmbiguous {
                    name: name.to_owned(),
                });
            }
            tree
        }
        ItemKind::Agent => {
            // The local source stores an agent as `agents/<name>.md` in
            // source form, so only a harness whose rendering round-trips
            // through the source parser can be forked. Claude's `.md` is
            // the proven one; a codex `.toml`, a cursor `.mdc`, or an
            // opencode `.md`-without-frontmatter cannot be re-read.
            if !forkable_harness(ItemKind::Agent, harness) {
                return Err(CoreError::ItemNotInSource {
                    name: name.to_owned(),
                    source_name: format!(
                        "{}'s copy of this agent is not in a forkable format — fork the Claude copy instead",
                        harness.display_name()
                    ),
                });
            }
            let Some(dir) = native_dir(env, scope, harness, ItemKind::Agent) else {
                return Err(CoreError::ItemNotFound {
                    kind,
                    name: name.to_owned(),
                    harness,
                });
            };
            existing_or_disabled(dir.join(crate::render::agent::file_name(harness, name)))
        }
        other => return Err(unsupported_kind(other, name)),
    };
    if edited.is_symlink() || !edited.exists() {
        return Err(CoreError::ItemNotFound {
            kind,
            name: name.to_owned(),
            harness,
        });
    }
    Ok(edited)
}

/// The edited bytes in source form: a skill's whole tree, an agent's one
/// file. A disabled rendering carries its SKILL.md under the `.disabled`
/// name; the local source holds source form, and the declaration's
/// `enabled` keeps the fork off when it renders — a tree copied verbatim
/// would be a skill source discovery cannot see.
enum Capture {
    Tree(Vec<(PathBuf, Vec<u8>)>),
    File(Vec<u8>),
}

/// What a fork takes from one installation: the bytes the local source
/// will hold, plus — for an agent — the catalog values that shaped its
/// rendering from outside its own file.
struct Captured {
    files: Capture,
    /// What the captured bytes render back to, where the capture goes
    /// through a renderer at all. `None` for a skill, whose tree is its
    /// own source form.
    rendering: Option<String>,
    carry: Option<crate::engine::agent_carry::AgentCarry>,
    /// The catalog revision an agent's bytes were read at, `None` for a
    /// skill: a skill's tree is one capture no per-tool rendering derives
    /// from, so no tool can be at odds with it.
    read_at: Option<String>,
}

/// One fork's inputs, gathered so the capture side reads them in one
/// place. `installed_as` is the name the fork will answer to — the
/// original's for a fork in place, the person's choice for one beside it.
struct ForkOf<'a> {
    env: &'a Env,
    scope: &'a Scope,
    manifest: &'a manifest::Manifest,
    decl: &'a manifest::ItemDecl,
    kind: ItemKind,
    name: &'a str,
    installed_as: &'a str,
    harness: HarnessId,
}

fn capture(of: &ForkOf, edited: &std::path::Path) -> Result<Captured> {
    Ok(match of.kind {
        ItemKind::Skill => Captured {
            files: Capture::Tree(source_form(crate::capture::read_tree(edited)?)),
            carry: None,
            read_at: None,
            rendering: None,
        },
        // Every other kind is turned away by `edited_rendering` first, so
        // what reaches here is an agent.
        _ => {
            let captured = capture_agent(of, edited)?;
            Captured {
                files: Capture::File(captured.bytes),
                carry: captured.carry,
                read_at: captured.read_at,
                rendering: Some(captured.rendering),
            }
        }
    })
}

fn capture_rendering(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
    manifest: &manifest::Manifest,
    decl: &manifest::ItemDecl,
) -> Result<(PathBuf, Captured)> {
    let edited = edited_rendering(env, scope, kind, name, harness)?;
    let captured = capture(
        &ForkOf {
            env,
            scope,
            manifest,
            decl,
            kind,
            name,
            installed_as: name,
            harness,
        },
        &edited,
    )?;
    Ok((edited, captured))
}

/// The bytes answering to `name`, refused as a fork's own refusal: bytes
/// whose name no single scalar can carry stop the whole operation rather
/// than land a copy that still answers to the old one.
fn named_bytes(bytes: Vec<u8>, name: &str) -> Result<Vec<u8>> {
    crate::render::skill::bytes_named(&bytes, name).map_err(|problem| CoreError::ForkNameUnusable {
        name: crate::names::shown(name),
        problem,
    })
}

/// The local source's path for an item of this kind under `name`.
fn local_item(env: &Env, scope: &Scope, kind: ItemKind, name: &str) -> PathBuf {
    crate::source::local_slot(&local_source_root(env, scope), kind, name)
}

/// The ops that move the edited bytes into the local source: a previous
/// local copy goes to the trash (never overwritten in place), the bytes
/// are captured under the same name, and the edited artifact itself goes
/// to the trash — bound to the exact bytes just captured (invariant 7) —
/// so the follow-up apply renders the fork in its place.
///
/// The slot has to be one this scope's local source can read back, asked
/// here rather than at each caller: a fork in place has no other name to ask
/// it of. `Pre::Absent` refuses a link wearing the item's own name, but a
/// link one component above leaves the slot absent past it, and the
/// capture lands at the far end, outside anything kendex manages.
fn capture_ops(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    edited: &std::path::Path,
    captured: Capture,
) -> Result<Vec<PlannedOp>> {
    let mut ops = into_local_source(env, scope, kind, name, captured)?;
    ops.push(PlannedOp {
        description: format!("clear the edited install of {name} for re-render").into(),
        op: Op::Trash {
            absent_is_done: false,
            pre: Pre::HashIs {
                hash: crate::hash::hash_tree(edited)?,
            },
            path: edited.to_path_buf(),
        },
    });
    Ok(ops)
}

/// The half of [`capture_ops`] that moves bytes into the local source: a
/// previous local copy goes to the trash (never overwritten in place) and
/// the captured bytes land under the same name.
fn into_local_source(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    captured: Capture,
) -> Result<Vec<PlannedOp>> {
    let local_item = local_item(env, scope, kind, name);
    if let Some(escape) = crate::source::slot_escapes(env, scope, &local_item)? {
        return Err(escape);
    }
    let mut ops = Vec::new();
    if local_item.exists() {
        ops.push(PlannedOp {
            description: format!("trash the local source's earlier copy of {name}").into(),
            op: Op::Trash {
                absent_is_done: false,
                path: local_item.clone(),
                pre: Pre::HashIs {
                    hash: crate::hash::hash_tree(&local_item)?,
                },
            },
        });
    }
    let capture = match captured {
        Capture::Tree(files) => Op::WriteTree {
            root: local_item,
            files,
            pre: Pre::Absent,
        },
        Capture::File(bytes) => Op::WriteFile {
            path: local_item,
            bytes,
            pre: Pre::Absent,
        },
    };
    ops.push(PlannedOp {
        description: format!("keep the edited {} {name} as a local fork", kind.name()).into(),
        op: capture,
    });
    Ok(ops)
}

/// Take an edit made to a fork's own installation into the fork's source,
/// leaving the installation exactly where it is. A fork is already the
/// person's copy, so its edit is its new content rather than a divergence
/// to settle: [`capture_ops`] clears the install because a fork's first
/// capture has to re-render it, and here those bytes are already what the
/// fork renders to.
///
/// Refuses everything `fork` refuses, and one thing more: catalog values
/// that shaped the rendering from outside its own file would have to move
/// into the manifest to survive, and a plan absorbing an edit writes no
/// manifest. Each refusal returns the item to the edit hold, which is the
/// conflict and the two named ways out it had before.
pub(super) fn absorb_ops(
    env: &Env,
    scope: &Scope,
    manifest: &manifest::Manifest,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
    edited: &std::path::Path,
) -> Result<Vec<PlannedOp>> {
    forkable_kind(kind, name)?;
    // The same format gate `edited_rendering` puts on a fork's capture,
    // asked here because an absorb reaches the capture without it. A
    // rendering the source parser cannot read back is not a rendering the
    // source can be written from: taken anyway, a codex agent's toml would
    // land in the local source as the agent's own prose.
    if !forkable_harness(kind, harness) {
        return Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name: format!(
                "{}'s copy of this {} is not in a form its source can hold",
                harness.display_name(),
                kind.name()
            ),
        });
    }
    let Some(decl) = manifest.declared(kind).get(name) else {
        return Err(CoreError::NotDeclared {
            kind,
            name: name.to_owned(),
        });
    };
    let captured = capture(
        &ForkOf {
            env,
            scope,
            manifest,
            decl,
            kind,
            name,
            installed_as: name,
            harness,
        },
        edited,
    )?;
    // The capture has to hold the whole edit. A rendering carries fields
    // its source form has nowhere to keep — an agent's `description:` and
    // `tags:` have no override table to ride into — and a fork answers
    // that by re-rendering the install over them. An absorb keeps the
    // install, so a capture that renders back to anything else would
    // leave the two disagreeing for good: the same never-settling state
    // this whole path exists to end. Asked of the renderer's own output,
    // never of a list of the fields that can be lost.
    if let Some(rendering) = &captured.rendering {
        let on_disk = std::fs::read_to_string(edited).map_err(|e| CoreError::io(edited, e))?;
        if rendering != &on_disk {
            return Err(CoreError::ForkWidensAccess {
                name: crate::names::shown(name),
                problem: "the edit changes something its source form cannot hold".into(),
            });
        }
    }
    // A carry the manifest already holds changes nothing and is no reason
    // to refuse: a fork's own carry is mostly what its first capture wrote
    // there, and reading the carry's presence as work outstanding would
    // leave every forked agent with skills at the conflict this absorb
    // exists to end. What decides it is whether applying it would move the
    // manifest, asked of `apply` itself rather than of a second reading of
    // its rule.
    if carry_needs_writing(manifest, name, captured.carry) {
        return Err(CoreError::ForkWidensAccess {
            name: crate::names::shown(name),
            problem: "its catalog settings would have to be written to kendex.toml first".into(),
        });
    }
    into_local_source(env, scope, kind, name, captured.files)
}

/// The path an agent's rendering stands at: a switched-off installation
/// keeps its bytes under the `.disabled` name.
fn existing_or_disabled(path: PathBuf) -> PathBuf {
    if path.exists() || path.is_symlink() {
        return path;
    }
    let disabled = PathBuf::from(format!("{}.disabled", path.display()));
    if disabled.exists() { disabled } else { path }
}

/// Whether this carry still has something to write into the manifest. The
/// plan that absorbs an edit writes no manifest, so a carry that would
/// move one has to stop the absorb; one the manifest already holds is
/// already recorded and stops nothing.
fn carry_needs_writing(
    manifest: &manifest::Manifest,
    name: &str,
    carry: Option<crate::engine::agent_carry::AgentCarry>,
) -> bool {
    let Some(carry) = carry else {
        return false;
    };
    let mut after = manifest.clone();
    carry.apply(&mut after, name);
    after.agent_skills != manifest.agent_skills
        || after.agent_frontmatter != manifest.agent_frontmatter
}
