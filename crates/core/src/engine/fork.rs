//! Keeping a user's edits: the edited installation becomes a local package
//! under the same name. Fork is adopt with provenance — the bytes move into
//! the scope's local source, the declaration flips to `local`, and the
//! manifest records what it replaced. The name never changes, so nothing
//! that depends on it breaks.

use std::fs;
use std::path::PathBuf;

use super::desired::{native_dir, skill_canonical};
use super::ops::manifest_for_mutation;
use crate::apply::{Op, Plan, PlannedOp, Pre};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{self, ForkProvenance, LOCAL_SOURCE_NAME};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::source::local_source_root;

mod beside;
mod forkable;
mod rename;
pub use beside::fork_beside;
use forkable::{ambiguous_skill_tree, source_form};
pub use forkable::{forkable_harness, forkable_rendering};
pub use rename::rename_fork;

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
    let edited = edited_rendering(env, scope, kind, name, harness)?;
    let captured = capture(kind, &edited)?;
    let mut ops = capture_ops(env, scope, kind, name, &edited, captured)?;
    let provenance = provenance(env, scope, kind, name, &manifest, &decl)?;
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
        description: format!("record the fork of {name} in kendex.toml"),
        op: Op::WriteManifest {
            pre: Pre::observed(&manifest_path)?,
            path: manifest_path,
            manifest: Box::new(manifest),
        },
    });
    Ok(Plan {
        scope: scope.clone(),
        ops,
    })
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

/// Where the original came from, recorded on the fork so the Library can
/// say what it replaced and which commit the edits were made on.
fn provenance(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    manifest: &manifest::Manifest,
    decl: &manifest::ItemDecl,
) -> Result<ForkProvenance> {
    Ok(ForkProvenance {
        repo: manifest
            .sources
            .get(&decl.source)
            .and_then(|s| s.repo.clone()),
        source: decl.source.clone(),
        commit: crate::lock::load(&crate::lock::lock_path(env, scope))?
            .entries
            .values()
            .filter(|entry| entry.kind == kind && entry.name == name)
            .find_map(|entry| entry.source_commit.clone()),
        forked_at: crate::clock::timestamp(),
    })
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

fn capture(kind: ItemKind, edited: &std::path::Path) -> Result<Capture> {
    Ok(match kind {
        ItemKind::Skill => Capture::Tree(source_form(super::adopt::read_tree(edited)?)),
        _ => Capture::File(fs::read(edited).map_err(|e| CoreError::io(edited, e))?),
    })
}

/// The local source's path for an item of this kind under `name`.
fn local_item(env: &Env, scope: &Scope, kind: ItemKind, name: &str) -> PathBuf {
    let local_root = local_source_root(env, scope);
    match kind {
        ItemKind::Skill => local_root.join("skills").join(name),
        _ => local_root.join("agents").join(format!("{name}.md")),
    }
}

/// Whether `new` can be declared here as a local item: a legal name, no
/// declaration of this kind under it, nothing in the local source's slot
/// for it — a dangling link included, which exists to the OS and to nothing
/// that follows it — and nothing that folds to it. A declared `Docs` beside
/// a new `docs`, or a `café` spelled two ways, renders to one path on a
/// case- or composition-folding filesystem, where the planner would refuse
/// both and sweep the one that was there; each tool's rendered name and a
/// local-source sibling fold the same way.
fn vacant_name(
    env: &Env,
    scope: &Scope,
    manifest: &manifest::Manifest,
    kind: ItemKind,
    new: &str,
) -> Result<()> {
    if let Some(problem) = crate::names::item_problem(new) {
        return Err(CoreError::ItemNotInSource {
            name: problem,
            source_name: "the new name".to_owned(),
        });
    }
    let collision = |existing: &str| CoreError::SourceCollision {
        name: new.to_owned(),
        existing: existing.to_owned(),
        requested: LOCAL_SOURCE_NAME.to_owned(),
    };
    let same_slot = |a: &str, b: &str| {
        crate::names::fold(a) == crate::names::fold(b)
            || HarnessId::ALL.iter().any(|harness| {
                crate::names::fold(&crate::harness::rendered_name(*harness, a))
                    == crate::names::fold(&crate::harness::rendered_name(*harness, b))
            })
            || crate::names::fold(&crate::harness::canonical_name(a))
                == crate::names::fold(&crate::harness::canonical_name(b))
    };
    if manifest
        .declared(kind)
        .keys()
        .any(|existing| same_slot(existing, new))
    {
        return Err(collision("this scope's manifest"));
    }
    if fs::symlink_metadata(local_item(env, scope, kind, new)).is_ok() {
        return Err(collision("this scope's local source"));
    }
    let slot = local_item(env, scope, kind, new);
    let siblings = slot
        .parent()
        .and_then(|dir| fs::read_dir(dir).ok())
        .into_iter()
        .flatten()
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.file_name().to_string_lossy().into_owned());
    for sibling in siblings {
        let sibling = match kind {
            ItemKind::Skill => sibling,
            _ => sibling.strip_suffix(".md").unwrap_or(&sibling).to_owned(),
        };
        if same_slot(&sibling, new) {
            return Err(collision("this scope's local source"));
        }
    }
    Ok(())
}

/// The ops that move the edited bytes into the local source: an earlier
/// local copy goes to the trash (never overwritten in place), the bytes
/// are captured under the same name, and the edited artifact itself goes
/// to the trash — bound to the exact bytes just captured (invariant 7) —
/// so the follow-up apply renders the fork in its place.
fn capture_ops(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    edited: &std::path::Path,
    captured: Capture,
) -> Result<Vec<PlannedOp>> {
    let local_item = local_item(env, scope, kind, name);
    let mut ops = Vec::new();
    if local_item.exists() {
        ops.push(PlannedOp {
            description: format!("trash the local source's earlier copy of {name}"),
            op: Op::Trash {
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
        description: format!("keep the edited {} {name} as a local fork", kind.name()),
        op: capture,
    });
    ops.push(PlannedOp {
        description: format!("clear the edited install of {name} for re-render"),
        op: Op::Trash {
            pre: Pre::HashIs {
                hash: crate::hash::hash_tree(edited)?,
            },
            path: edited.to_path_buf(),
        },
    });
    Ok(ops)
}

/// The tree that holds a skill's content for one harness: its own native
/// tree when it was copied there (each tool a real directory), or the
/// shared canonical tree when tools symlink to one. Picking canonical-first
/// would capture whichever tool happens to share it, not the one asked for.
pub(crate) fn skill_content_path(
    env: &Env,
    scope: &Scope,
    name: &str,
    harness: HarnessId,
) -> Option<PathBuf> {
    if let Some(dir) = native_dir(env, scope, harness, ItemKind::Skill) {
        let native = dir.join(crate::harness::rendered_name(harness, name));
        // A real directory here is this tool's own copy (copy method). A
        // symlink is followed to the tree this tool actually reads — the
        // shared canonical tree, or its own divergent variant under the
        // variants directory. Resolving it gives a real directory either
        // way, never the wrong tool's bytes.
        if native.is_symlink() {
            if let Ok(target) = std::fs::read_link(&native) {
                let resolved = if target.is_absolute() {
                    target
                } else {
                    dir.join(target)
                };
                // Only a link into a location kendex itself manages is
                // followed — the shared canonical tree or this tool's
                // variant. A foreign link the user pointed elsewhere is
                // not this skill's content, and reading (then trashing) it
                // would expose and move whatever it happens to point at.
                if resolved.is_dir() && managed_skill_tree(env, scope, name, &resolved) {
                    return Some(resolved);
                }
            }
        } else if native.is_dir() {
            return Some(native);
        }
    }
    let canonical = skill_canonical(env, scope, name);
    canonical.is_dir().then_some(canonical)
}

/// Whether `path` is a skill tree kendex manages for `name`: the shared
/// canonical tree, or a per-tool variant under the rendered-variants
/// directory. Compared canonically so a `..`-laden link cannot dress a
/// foreign directory up as a managed one.
fn managed_skill_tree(env: &Env, scope: &Scope, name: &str, path: &std::path::Path) -> bool {
    let real = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    let canonical = skill_canonical(env, scope, name);
    if real == canonical.canonicalize().unwrap_or(canonical) {
        return true;
    }
    // Variant trees live below the rendered-variants root, one dir per
    // harness. Any harness's variant of this name is a managed tree.
    let _ = scope;
    HarnessId::ALL.iter().any(|h| {
        let variant = env.rendered_skill_variants_dir(h.name()).join(name);
        real == variant.canonicalize().unwrap_or(variant)
    })
}

/// Whether an agent rendered for this harness can be re-read as local
/// source. Only the plain `.md`-with-frontmatter shape round-trips; codex
/// (TOML), cursor (`.mdc`), copilot (`.agent.md`), and opencode (`.md`
/// without a name field) do not.
/// A disabled installation keeps its bytes under the `.disabled` name.
fn existing_or_disabled(path: PathBuf) -> PathBuf {
    if path.exists() || path.is_symlink() {
        return path;
    }
    let disabled = PathBuf::from(format!("{}.disabled", path.display()));
    if disabled.exists() { disabled } else { path }
}
