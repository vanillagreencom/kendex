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
use forkable::{ambiguous_skill_tree, source_form};
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
/// The plan: capture the edited bytes into the local source (an earlier
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
    let edited = edited_rendering(env, scope, kind, name, harness)?;
    let captured = capture(
        &ForkOf {
            env,
            scope,
            manifest: &manifest,
            decl: &decl,
            kind,
            name,
            installed_as: name,
            harness,
        },
        &edited,
    )?;
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
        other => {
            return Err(CoreError::ItemNotInSource {
                name: name.to_owned(),
                source_name: format!("fork does not support {} yet", other.name()),
            });
        }
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
        },
        // Every other kind is turned away by `edited_rendering` first, so
        // what reaches here is an agent.
        _ => {
            let captured = capture_agent(of, edited)?;
            Captured {
                files: Capture::File(captured.bytes),
                carry: captured.carry,
                read_at: captured.read_at,
            }
        }
    })
}

/// The files of a skill's tree that carry the name the item answers to:
/// SKILL.md under either spelling, because a switched-off installation
/// keeps its content under the `.disabled` name and that is the same
/// claim on the same name. An agent's source is one file, so the file
/// itself is the one — no list to consult.
const SKILL_NAME_FILES: [&str; 2] = ["SKILL.md", "SKILL.md.disabled"];

fn carries_name(rel: &std::path::Path) -> bool {
    rel.to_str()
        .is_some_and(|rel| SKILL_NAME_FILES.contains(&rel))
}

/// The bytes answering to `name`. A tool knows a skill or an agent by the
/// name its frontmatter gives, and the loader validators refuse a
/// rendering whose file calls it something other than the name it
/// installs under — so a copy landing under a new name says that name.
/// A frontmatter without a name gets one, exactly as rendering would give
/// it one; bytes whose name no single scalar can carry refuse the whole
/// operation rather than land a copy that still answers to the old name.
fn named_bytes(bytes: Vec<u8>, name: &str) -> Result<Vec<u8>> {
    let refused = |problem: String| CoreError::ForkNameUnusable {
        name: crate::names::shown(name),
        problem,
    };
    let text =
        std::str::from_utf8(&bytes).map_err(|_| refused("the file is not text".to_owned()))?;
    crate::render::skill::with_name(text, name)
        .map(String::into_bytes)
        .map_err(|problem| refused(problem.to_string()))
}

/// The local source's path for an item of this kind under `name`.
fn local_item(env: &Env, scope: &Scope, kind: ItemKind, name: &str) -> PathBuf {
    let local_root = local_source_root(env, scope);
    match kind {
        ItemKind::Skill => local_root.join("skills").join(name),
        _ => local_root.join("agents").join(format!("{name}.md")),
    }
}

/// The ops that move the edited bytes into the local source: an earlier
/// local copy goes to the trash (never overwritten in place), the bytes
/// are captured under the same name, and the edited artifact itself goes
/// to the trash — bound to the exact bytes just captured (invariant 7) —
/// so the follow-up apply renders the fork in its place.
///
/// The slot has to be one this scope's local source can read back, asked
/// here rather than at each caller: a fork in place has no new name to ask
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

/// The path an agent's rendering stands at: a switched-off installation
/// keeps its bytes under the `.disabled` name.
fn existing_or_disabled(path: PathBuf) -> PathBuf {
    if path.exists() || path.is_symlink() {
        return path;
    }
    let disabled = PathBuf::from(format!("{}.disabled", path.display()));
    if disabled.exists() { disabled } else { path }
}
