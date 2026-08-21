use std::fs;
use std::path::{Path, PathBuf};

use super::adopt_shared::{SharedTarget, shared_capture_ops, shared_target};
use super::desired::native_dir;
use super::ops::manifest_for_mutation;
use crate::apply::{Op, Plan, PlannedOp, Pre};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{self, ItemDecl, LOCAL_SOURCE_NAME};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::source::local_source_root;

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
    matches!(kind, ItemKind::Agent | ItemKind::Skill)
}

/// Every tool the item is blocked for is answered by one plan. Handed over
/// one tool at a time, each capture wrote over the last in the local source
/// and the declaration stayed pinned to the first tool — the last tool left
/// unmanaged and the earlier copies only in the trash.
pub fn adopt(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harnesses: &[HarnessId],
) -> Result<Plan> {
    let mut manifest = manifest_for_mutation(env, scope)?;
    let local_item = local_item_path(env, scope, kind, name)?;

    let mut positions: Vec<(HarnessId, PathBuf)> = Vec::new();
    for &harness in harnesses {
        let Some(original) = position(env, scope, kind, name, harness) else {
            return Err(CoreError::ItemNotInSource {
                name: name.to_owned(),
                source_name: format!("{} {}", harness.name(), kind.name()),
            });
        };
        // Two tools reading one directory sit at one position, captured once.
        if !positions.iter().any(|(_, path)| path == &original) {
            positions.push((harness, original));
        }
    }
    let Some((_, first_position)) = positions.first() else {
        return Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name: "no tool was named to keep it for".to_owned(),
        });
    };

    let Seen {
        shared,
        content,
        broken,
    } = look(env, scope, kind, name, &positions, &local_item)?;
    if shared.is_none() && content.is_empty() && !local_item.exists() {
        return Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name: format!("nothing at {} to adopt", first_position.display()),
        });
    }

    let mut ops: Vec<PlannedOp> = broken
        .into_iter()
        .map(|(path, pre)| PlannedOp {
            description: format!("clear the broken link at {}", path.display()),
            op: Op::Trash { path, pre },
        })
        .collect();
    match &shared {
        Some((_, shared)) => ops.extend(shared_capture_ops(name, shared, &local_item)?),
        None => ops.extend(capture_ops(kind, name, &content, &local_item)?),
    }

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
    declare(&mut manifest, kind, name, wanted, already_declared);

    let manifest_path = manifest::manifest_path(env, scope);
    ops.push(PlannedOp {
        description: "declare the adopted item in kendex.toml".into(),
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

/// The place one tool reads this item from — the only place adoption looks
/// for it. Read wherever a surface asks whether adoption could keep a
/// tool's copy, so the question and the action are one rule: an offer
/// naming a tool that has nothing here would error the moment it was
/// followed.
pub(super) fn position(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
) -> Option<PathBuf> {
    let dir = native_dir(env, scope, harness, kind)?;
    Some(match kind {
        ItemKind::Agent => dir.join(crate::render::agent::file_name(harness, name)),
        _ => dir.join(name),
    })
}

/// Whether this tool has something adoption can keep. A tool with an empty
/// position is never named in an offer: adoption works at that position and
/// nowhere else, and the folder a link points at is reached through the
/// tool whose own place is the link.
pub fn can_keep_for(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
) -> bool {
    supports(kind)
        && position(env, scope, kind, name, harness)
            .is_some_and(|path| path.exists() || path.is_symlink())
}

/// Where in the scope's local source the kept content lands. Read wherever
/// a surface asks whether adoption could take a position, so the question
/// and the answer are never two different rules.
pub(super) fn local_item_path(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
) -> Result<PathBuf> {
    let local_root = local_source_root(env, scope);
    match kind {
        ItemKind::Skill => Ok(local_root.join("skills").join(name)),
        ItemKind::Agent => Ok(local_root.join("agents").join(format!("{name}.md"))),
        other => Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name: format!("adopt does not support {} yet", other.name()),
        }),
    }
}

/// What the named tools have where the item goes: a shared folder several
/// of them link at, the plain copies they hold, and the links whose target
/// is gone.
struct Seen {
    shared: Option<(HarnessId, SharedTarget)>,
    content: Vec<(HarnessId, PathBuf)>,
    broken: Vec<(PathBuf, Pre)>,
}

/// One copy goes into the local source, so every tool's copy has to be that
/// copy. Picking one and writing it over the rest is how content gets lost,
/// and only the reader can say which to keep — so tools that disagree
/// refuse here rather than being merged.
fn look(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    positions: &[(HarnessId, PathBuf)],
    local_item: &Path,
) -> Result<Seen> {
    let mut seen = Seen {
        shared: None,
        content: Vec::new(),
        broken: Vec::new(),
    };
    for (harness, original) in positions {
        if original.is_symlink() {
            let points_to = fs::read_link(original).map_err(|e| CoreError::io(original, e))?;
            // Broken link: content is gone; declaring is all adoption can
            // do. The link itself is cleared by a planned op — planning
            // never touches disk, so a plan that is never applied (or
            // fails) leaves the world as it was.
            if !original.exists() {
                seen.broken
                    .push((original.clone(), Pre::SymlinkTo { target: points_to }));
                continue;
            }
            let target = shared_target(env, scope, kind, name, original, points_to, local_item)?;
            match &seen.shared {
                Some((_, first)) if first.target == target.target => {}
                Some((first, _)) => return Err(copies_differ(name, *first, *harness)),
                None => seen.shared = Some((*harness, target)),
            }
            continue;
        }
        if original.exists() {
            seen.content.push((*harness, original.clone()));
        }
    }
    // A tool whose own position IS the folder the others link at holds the
    // same files, not a second copy — the hand-made sharing layout, where
    // one real folder sits at one tool's place and the rest read it through
    // links. Folded into the shared capture rather than called a
    // disagreement; only a position that resolves somewhere else is one.
    if let Some((_, shared)) = &seen.shared {
        let target = shared.target.clone();
        seen.content
            .retain(|(_, path)| path.canonicalize().is_ok_and(|at| at != target));
    }
    if let (Some((linked, _)), Some((held, _))) = (seen.shared.as_ref(), seen.content.first()) {
        return Err(copies_differ(name, *linked, *held));
    }
    if let Some((first, first_path)) = seen.content.first() {
        let hash = crate::hash::hash_tree(first_path)?;
        for (harness, path) in &seen.content[1..] {
            if crate::hash::hash_tree(path)? != hash {
                return Err(copies_differ(name, *first, *harness));
            }
        }
    }
    Ok(seen)
}

/// Write the item into the manifest, bound to the tools that had it. Only
/// when the [install] defaults name exactly that set may the list be left
/// off: a wider default would install the item for tools the user never
/// gave it to.
fn declare(
    manifest: &mut manifest::Manifest,
    kind: ItemKind,
    name: &str,
    wanted: Vec<HarnessId>,
    already_declared: bool,
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
        .or_insert_with(|| ItemDecl::from_source(LOCAL_SOURCE_NAME));
    decl.source = LOCAL_SOURCE_NAME.to_owned();
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

/// The one copy every tool had goes into the local source, and every
/// position it sat at is cleared. Nothing here runs at plan time: every
/// byte read becomes an op.
fn capture_ops(
    kind: ItemKind,
    name: &str,
    content: &[(HarnessId, PathBuf)],
    local_item: &Path,
) -> Result<Vec<PlannedOp>> {
    let mut ops = Vec::new();
    let Some((_, source)) = content.first() else {
        return Ok(ops);
    };
    // A copy the local source already holds is not overwritten in place:
    // it goes to the trash first, where it can be got back.
    if local_item.exists() {
        ops.push(PlannedOp {
            description: format!("trash the local source's earlier copy of {name}"),
            op: Op::Trash {
                path: local_item.to_path_buf(),
                pre: Pre::HashIs {
                    hash: crate::hash::hash_tree(local_item)?,
                },
            },
        });
    }
    let capture = match kind {
        ItemKind::Skill => Op::WriteTree {
            root: local_item.to_path_buf(),
            files: read_tree(source)?,
            pre: Pre::Absent,
        },
        _ => Op::WriteFile {
            path: local_item.to_path_buf(),
            bytes: fs::read(source).map_err(|e| CoreError::io(source, e))?,
            pre: Pre::Absent,
        },
    };
    ops.push(PlannedOp {
        description: format!("move {name} into the local source"),
        op: capture,
    });
    for (_, original) in content {
        ops.push(PlannedOp {
            description: format!("trash the unmanaged original at {}", original.display()),
            op: Op::Trash {
                path: original.clone(),
                pre: Pre::Any,
            },
        });
    }
    Ok(ops)
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

pub(super) mod capture;

pub(crate) use capture::read_tree;

#[cfg(test)]
mod tests;
