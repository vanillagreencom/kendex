//! Keeping a user's edits: the edited installation becomes a local package
//! under the same name. Fork is adopt with provenance — the bytes move into
//! the scope's local source, the declaration flips to `local`, and the
//! manifest records what it replaced. The name never changes, so nothing
//! that depends on it breaks.

use std::path::PathBuf;

#[cfg(test)]
#[path = "fork/tests.rs"]
mod scope_manifest_messages;

use super::WritePlan;
use super::desired::native_dir;
use super::ops::manifest_for_mutation;
use crate::apply::{Op, Plan, PlannedOp, Pre};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{self, LOCAL_SOURCE_NAME};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::render::skill::links;
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
) -> Result<WritePlan> {
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
    if manifest::is_reserved_source(&decl.source) {
        return Err(CoreError::AlreadyOwn {
            name: name.to_owned(),
            origin: decl.source.clone(),
        });
    }
    let (edited, captured) = capture_rendering(env, scope, kind, name, harness, &manifest, &decl)?;
    let warnings = kept_warnings(name, &captured.kept);
    let mut ops = capture_ops(env, scope, kind, name, &edited, captured.files)?;
    let provenance = provenance(&manifest, &decl, captured.read_at);
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
    entry.links = captured.links;
    manifest
        .forks
        .entry(kind)
        .or_default()
        .insert(name.to_owned(), provenance);

    let manifest_path = manifest::manifest_path(env, scope);
    ops.push(PlannedOp {
        description: format!(
            "record the fork of {name} in {}",
            manifest::manifest_file_name(env, scope)
        )
        .into(),
        op: Op::WriteManifest {
            pre: Pre::observed(&manifest_path)?,
            path: manifest_path,
            manifest: Box::new(manifest),
        },
    });
    Ok(WritePlan {
        plan: Plan::landed(scope.clone(), ops)?,
        warnings,
    })
}

/// What a fork's capture reports: each link it kept as written.
fn kept_warnings(name: &str, kept: &[links::KeptLink]) -> Vec<crate::engine::ItemWarning> {
    kept.iter()
        .map(|link| links::kept_warning(name, link))
        .collect()
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

/// The edited bytes in source form: a skill's rendered tree, an agent's one
/// file. A render leaves out the catalog's top-level `tests/`, `evals/` and
/// `DEVELOPMENT.md`, so a skill's fork holds none of them; the plan's
/// capture line says so. A disabled rendering carries its SKILL.md under the `.disabled`
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
    /// Whether the captured bytes render back to the bytes they were
    /// captured from.
    round_trips: bool,
    carry: Option<crate::engine::agent_carry::AgentCarry>,
    /// The catalog revision the publisher's file was read at, which the
    /// fork records as the commit its edits were made on.
    read_at: Option<String>,
    /// The reading a skill's captured links were stored in, which the
    /// fork's declaration records.
    links: Option<manifest::SkillLinks>,
    /// The links the capture kept as written.
    kept: Vec<crate::render::skill::links::KeptLink>,
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

/// The catalog an installation's bytes were published in, opened at the
/// commit they were installed from, and the item's path inside it.
struct PublishedItem {
    sealed: crate::source_read::SealedSource,
    config: crate::source::SourceConfig,
    path: PathBuf,
    commit: Option<String>,
}

/// The published agent behind this fork, read through the declaration at
/// the commit [`installed_commit`] picks. A skill's capture reads its
/// install record instead ([`crate::source::header::published_text`]).
/// Nothing is fetched: a source this machine holds no copy of at that
/// commit refuses with the cause [`crate::source::require_ready_at`]
/// gives, because a capture without the publisher's file would drop what
/// only that file declares.
fn published_item(of: &ForkOf) -> Result<PublishedItem> {
    let ForkOf {
        env,
        scope,
        manifest,
        decl,
        kind,
        name,
        harness,
        ..
    } = *of;
    let commit = installed_commit(env, scope, kind, name, harness, decl)?;
    let resolved =
        crate::source::require_ready_at(env, scope, &decl.source, manifest, commit.as_deref())?;
    let sealed = crate::source_read::SealedSource::open(&resolved.root)?;
    let config = crate::source::source_config_for(&sealed, &resolved.provenance)?;
    let Some(path) = crate::source::find_item(&sealed, &config, kind, name) else {
        return Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name: decl.source.clone(),
        });
    };
    Ok(PublishedItem {
        sealed,
        config,
        path,
        commit,
    })
}

fn capture(of: &ForkOf, edited: &std::path::Path) -> Result<Captured> {
    Ok(match of.kind {
        ItemKind::Skill => {
            let files = source_form(crate::capture::read_tree(edited)?);
            let unrestored = |cause: String| CoreError::ForkWidensAccess {
                name: crate::names::shown(of.name),
                problem: format!("the publisher's keys, because {cause}"),
            };
            // The copy carries only the installed key set; the
            // publisher's other keys come back from the file it was
            // rendered from, around the person's edits, at the revision
            // the record that wrote this copy names.
            let lock = crate::lock::load(&crate::lock::lock_path(of.env, of.scope))?;
            let installed =
                crate::library::record_at(of.env, of.scope, &lock, (of.kind, of.name), edited)
                    .map(crate::source::header::InstalledFrom::of);
            let published = crate::source::header::published_text(
                of.env,
                of.scope,
                of.manifest,
                (of.kind, of.name),
                installed.as_ref(),
            )?
            .map_err(unrestored)?;
            let on_disk = files.clone();
            let files = crate::render::skill::authored_form(files, &published.text)
                .map_err(|cause| unrestored(cause.to_string()))?;
            let stored = stored_reading(of);
            let (files, kept) = match &stored {
                Some(position) => links::convert(
                    links::Origin::new(
                        links::observed(of.env, of.scope, of.name, edited.to_path_buf()),
                        files,
                        links::Siblings::SkillsDirectory,
                        Vec::new(),
                    ),
                    position,
                ),
                None => (files, Vec::new()),
            };
            Captured {
                round_trips: skill_round_trip(of, &files, &on_disk, edited, stored.as_ref()),
                files: Capture::Tree(files),
                carry: None,
                read_at: published.commit,
                links: stored.map(|_| manifest::SkillLinks::SharedTree),
                kept,
            }
        }
        // Every other kind is turned away by `edited_rendering` first, so
        // what reaches here is an agent.
        _ => {
            let captured = capture_agent(of, edited)?;
            let on_disk = std::fs::read_to_string(edited).map_err(|e| CoreError::io(edited, e))?;
            Captured {
                files: Capture::File(captured.bytes),
                carry: captured.carry,
                read_at: captured.read_at,
                round_trips: captured.rendering == on_disk,
                links: None,
                kept: Vec::new(),
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
    let kept = format!("keep the edited {} {name} as a local fork", kind.name());
    let (description, capture) = match captured {
        Capture::Tree(files) => (
            format!(
                "{kept}: its rendered files, without the top-level tests/, evals/ and \
                 DEVELOPMENT.md a render leaves out"
            ),
            Op::WriteTree {
                root: local_item,
                files,
                pre: Pre::Absent,
            },
        ),
        Capture::File(bytes) => (
            kept,
            Op::WriteFile {
                path: local_item,
                bytes,
                pre: Pre::Absent,
            },
        ),
    };
    ops.push(PlannedOp {
        description: description.into(),
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
    // The other gate `edited_rendering` puts on a skill, asked here for the
    // same reason: `source_form` gives both spellings of SKILL.md the one
    // name, so a tree holding both would go into the source as whichever
    // the write reached last.
    if kind == ItemKind::Skill && ambiguous_skill_tree(edited) {
        return Err(CoreError::ForkAmbiguous {
            name: name.to_owned(),
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
    if !captured.round_trips {
        return Err(CoreError::ForkWidensAccess {
            name: crate::names::shown(name),
            problem: "the edit changes something its source form cannot hold".into(),
        });
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
            problem: format!(
                "its catalog settings would have to be written to {} first",
                manifest::manifest_file_name(env, scope)
            ),
        });
    }
    // A link the capture kept needs no report of its own here: read from
    // the stored reading it either still falls outside the bound, which the
    // render warns about, or reaches another file, which the round trip
    // above already refused back to the edit hold.
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

/// Whether a captured skill tree renders back to what is on disk at
/// `edited`. A skill's tree is nearly its own source form, but not quite: the renderer
/// strips and re-injects the project-instructions block, so bytes written
/// inside that block are not bytes a source can hold; it cuts the
/// frontmatter to the installed key set, which the capture put the
/// publisher's other keys back around; and a tree stored in the shared-tree
/// reading renders its links back to this position. What the round trip
/// asks is whether the captured source renders to the bytes on disk: every
/// text file, with each link compared by the target it reaches there.
fn skill_round_trip(
    of: &ForkOf,
    captured: &[(PathBuf, Vec<u8>)],
    on_disk: &[(PathBuf, Vec<u8>)],
    edited: &std::path::Path,
    stored: Option<&links::Position>,
) -> bool {
    let instructions = crate::render::skill::skill_instructions(of.manifest, of.name);
    let rendered = match stored {
        Some(position) => {
            links::convert(
                links::Origin::new(
                    position.clone(),
                    captured.to_vec(),
                    links::Siblings::SkillsDirectory,
                    Vec::new(),
                ),
                &links::Position {
                    directory: edited.to_path_buf(),
                    bound: position.bound.clone(),
                },
            )
            .0
        }
        None => captured.to_vec(),
    };
    let rendered = crate::render::skill::with_skill_text(rendered, |text| {
        crate::render::skill::installed_keys(&crate::render::skill::inject_instructions(
            text,
            instructions.as_deref(),
        ))
    });
    links::comparable_tree(&rendered, edited) == links::comparable_tree(on_disk, edited)
}

/// Where a skill fork keeps its captured links: the shared-tree reading of
/// the name it answers to, for a new fork and for a fork already tagged;
/// nowhere for a fork stored before kendex converted links, whose bytes
/// stay as delivered.
fn stored_reading(of: &ForkOf) -> Option<links::Position> {
    (!links::as_delivered(of.decl.into()))
        .then(|| links::shared_tree(of.env, of.scope, of.installed_as))
}
