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
    let edited = match kind {
        ItemKind::Skill => skill_content_path(env, scope, name, harness).ok_or({
            CoreError::ItemNotFound {
                kind,
                name: name.to_owned(),
                harness,
            }
        })?,
        ItemKind::Agent => {
            // The local source stores an agent as `agents/<name>.md` in
            // source form, so only a harness whose rendering round-trips
            // through the source parser can be forked. Claude's `.md` is
            // the proven one; a codex `.toml`, a cursor `.mdc`, or an
            // opencode `.md`-without-frontmatter cannot be re-read.
            if !forkable_agent_harness(harness) {
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

    let mut ops = capture_ops(env, scope, kind, name, &edited)?;

    let provenance = ForkProvenance {
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
    };
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
) -> Result<Vec<PlannedOp>> {
    let local_root = local_source_root(env, scope);
    let local_item = match kind {
        ItemKind::Skill => local_root.join("skills").join(name),
        _ => local_root.join("agents").join(format!("{name}.md")),
    };
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
    let capture = match kind {
        ItemKind::Skill => Op::WriteTree {
            root: local_item,
            files: super::adopt::read_tree(edited)?,
            pre: Pre::Absent,
        },
        _ => Op::WriteFile {
            path: local_item,
            bytes: fs::read(edited).map_err(|e| CoreError::io(edited, e))?,
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

/// Rename a fork. Only a fork nothing depends on may change its installed
/// name: dependents and bundles refer to the old one, and a rename that
/// breaks them is not a rename, it is a removal wearing one's clothes.
pub fn rename_fork(env: &Env, scope: &Scope, kind: ItemKind, old: &str, new: &str) -> Result<Plan> {
    let mut manifest = manifest_for_mutation(env, scope)?;
    if !manifest
        .forks
        .get(&kind)
        .is_some_and(|forks| forks.contains_key(old))
    {
        return Err(CoreError::NotDeclared {
            kind,
            name: old.to_owned(),
        });
    }
    if let Some(problem) = crate::names::item_problem(new) {
        return Err(CoreError::ItemNotInSource {
            name: problem,
            source_name: "the new name".to_owned(),
        });
    }
    if manifest.declared(kind).contains_key(new) {
        return Err(CoreError::SourceCollision {
            name: new.to_owned(),
            existing: "this scope's manifest".to_owned(),
            requested: LOCAL_SOURCE_NAME.to_owned(),
        });
    }
    let lock = crate::lock::load(&crate::lock::lock_path(env, scope))?;
    let depended_on = lock
        .entries
        .values()
        .filter(|entry| entry.kind == kind && entry.name == old)
        .flat_map(|entry| entry.reasons.iter())
        .any(|reason| !matches!(reason, crate::lock::Reason::Requested));
    if depended_on {
        return Err(CoreError::ManifestInvalid {
            path: manifest::manifest_path(env, scope),
            findings: vec![format!(
                "{}.{old}: other items depend on this name — fix: rename what depends on it first, or keep the name",
                kind.name()
            )],
        });
    }

    let local_root = local_source_root(env, scope);
    let (from, to) = match kind {
        ItemKind::Skill => (
            local_root.join("skills").join(old),
            local_root.join("skills").join(new),
        ),
        _ => (
            local_root.join("agents").join(format!("{old}.md")),
            local_root.join("agents").join(format!("{new}.md")),
        ),
    };
    let mut ops = Vec::new();
    if from.exists() {
        ops.push(PlannedOp {
            description: format!("rename the fork's files to {new}"),
            op: Op::Rename {
                from,
                to,
                to_pre: Pre::Absent,
            },
        });
    }
    let Some(decl) = manifest.declared_mut(kind).remove(old) else {
        return Err(CoreError::NotDeclared {
            kind,
            name: old.to_owned(),
        });
    };
    manifest.declared_mut(kind).insert(new.to_owned(), decl);
    if let Some(forks) = manifest.forks.get_mut(&kind)
        && let Some(provenance) = forks.remove(old)
    {
        forks.insert(new.to_owned(), provenance);
    }
    manifest.rename_decisions(kind, old, new);
    let manifest_path = manifest::manifest_path(env, scope);
    ops.push(PlannedOp {
        description: format!("record the rename to {new} in kendex.toml"),
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
/// Whether keeping an edit as a fork can capture this rendering: a skill's
/// canonical tree always round-trips, an agent's only from the tools whose
/// format the source parser reads back. The Updates page asks before it
/// offers the action, so the answer is the same one `fork` enforces.
pub fn forkable_harness(kind: ItemKind, harness: HarnessId) -> bool {
    match kind {
        ItemKind::Skill => true,
        ItemKind::Agent => forkable_agent_harness(harness),
        _ => false,
    }
}

fn forkable_agent_harness(harness: HarnessId) -> bool {
    matches!(
        harness,
        HarnessId::Claude | HarnessId::Gemini | HarnessId::Pi
    )
}

/// A disabled installation keeps its bytes under the `.disabled` name.
fn existing_or_disabled(path: PathBuf) -> PathBuf {
    if path.exists() || path.is_symlink() {
        return path;
    }
    let disabled = PathBuf::from(format!("{}.disabled", path.display()));
    if disabled.exists() { disabled } else { path }
}
