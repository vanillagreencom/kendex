//! Adopting a folder several tools already share by hand: the boundary that
//! decides what a link may be adopted through, and the ops that take the
//! folder over without breaking the tools reading it.

use std::fs;
use std::path::{Path, PathBuf};

use crate::apply::{Op, PlannedOp, Pre};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::source::local_source_root;

use super::{destination, position};

// Adopting a shared folder through the link a tool reads it by: the
// boundary that decides what a link may be adopted through, and the ops
// that take the folder over without breaking the other tools reading it.

/// A live symlink's resolved target, once it has passed the boundary: the
/// real folder whose content is being adopted, and every native link (with
/// the text it was written with) that resolves to it.
pub(super) struct SharedTarget {
    pub(super) target: PathBuf,
    /// Link path → the target exactly as the link spells it, so the
    /// removal's precondition catches a link repointed between plan and
    /// apply.
    pub(super) links: Vec<(PathBuf, PathBuf)>,
    /// Every tool whose native link reads this folder.
    pub(super) harnesses: Vec<HarnessId>,
}

/// What a live link may be adopted through. The target must be a real
/// skill folder — the `SKILL.md` marker is what keeps a link at `$HOME` or
/// `/etc` refused — and must sit outside kendex's own machinery: the
/// rendered canonical and variant trees, the trash, the source cache, the
/// journal, and the local source the capture would write into (a managed
/// tree is already ours, and capturing it under another name would steal
/// it; capturing the destination would recurse). Everything is compared
/// canonicalized, so a `..`-laden link cannot dress one side up as the
/// other. Anything that fails stays what it was: a foreign symlink,
/// reported as a conflict.
pub(super) fn shared_target(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    original: &Path,
    points_to: PathBuf,
    local_item: &Path,
) -> Result<SharedTarget> {
    let refuse = || CoreError::ForeignSymlink {
        target: original.to_path_buf(),
        points_to: points_to.clone(),
    };
    // Only a skill directory has the marker that makes the boundary
    // checkable; an agent's file link stays a conflict.
    if kind != ItemKind::Skill {
        return Err(refuse());
    }
    let target = fs::canonicalize(original).map_err(|e| CoreError::io(original, e))?;
    if !target.is_dir() || !target.join("SKILL.md").is_file() {
        return Err(refuse());
    }
    let canon = |path: PathBuf| path.canonicalize().unwrap_or(path);
    let mut ours = vec![
        env.rendered_skills_dir(),
        env.trash_dir(),
        env.source_cache_dir(),
        env.journal_dir(),
        local_source_root(env, scope),
    ];
    ours.extend(
        HarnessId::ALL
            .iter()
            .map(|h| env.rendered_skill_variants_dir(h.name())),
    );
    if ours.into_iter().any(|root| target.starts_with(canon(root))) {
        return Err(refuse());
    }
    // Capturing into the folder being captured would recurse — unless the
    // two are exactly the same place, which is a skill already sitting where
    // adoption would put it, with tools linking at it. That is the finished
    // shape, not a refusal.
    //
    // Anywhere *else* inside the destination's own tree stays refused, the
    // in-place home included: a link at `foo` pointing into
    // `.agents/skills/bar` would have adoption move `bar` under the name
    // `foo`, taking a second skill's content with it.
    let home = local_item.canonicalize();
    let is_home = home.as_deref().unwrap_or(local_item) == target;
    if !is_home
        && (local_item.starts_with(&target)
            || destination_tree(local_item).is_some_and(|tree| target.starts_with(tree)))
    {
        return Err(refuse());
    }

    let mut links = Vec::new();
    let mut harnesses = Vec::new();
    for h in HarnessId::ALL {
        let Some(candidate) = position(env, scope, ItemKind::Skill, name, h) else {
            continue;
        };
        let Ok(resolved) = fs::canonicalize(&candidate) else {
            continue;
        };
        if resolved != target {
            continue;
        }
        // The tool whose own place IS the folder reads it too — in the
        // hand-made layout it is the one holding it, and the rest link at
        // it. Left out, adoption would settle the others and quietly drop
        // this one from the declaration, taking the skill away from the
        // tool that had it all along. It has no link to clear.
        harnesses.push(h);
        if candidate.is_symlink() && !links.iter().any(|(path, _)| path == &candidate) {
            let raw = fs::read_link(&candidate).map_err(|e| CoreError::io(&candidate, e))?;
            links.push((candidate, raw));
        }
    }
    Ok(SharedTarget {
        target,
        links,
        harnesses,
    })
}

/// The tree the destination itself lives in — `.agents/skills` for a skill
/// adopted in place, the local source's `skills` directory otherwise. A link
/// pointing anywhere inside it names content that already has a home of its
/// own, which is never this item's to move.
fn destination_tree(local_item: &Path) -> Option<&Path> {
    local_item.parent()
}

/// What adoption would take over at this position, or nothing where the
/// link is one adoption would refuse. The planner asks through the same
/// boundary the adoption itself applies, so the offer and the action can
/// never drift apart.
fn shared_at(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    link: &Path,
) -> Option<SharedTarget> {
    let points_to = fs::read_link(link).ok()?;
    let local_item = destination(env, scope, kind, name).ok()?;
    shared_target(env, scope, kind, name, link, points_to, &local_item).ok()
}

/// Every tool adoption will act on for this position. A folder shared by
/// hand is read by whoever links at it, declared or not, and taking it
/// over clears each of those links — so a surface offering the move has to
/// name them all, or it acts on a tool it never mentioned.
pub(crate) fn shared_tools(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    link: &Path,
) -> Option<Vec<HarnessId>> {
    shared_at(env, scope, kind, name, link).map(|s| s.harnesses)
}

/// The folder a link at this position could be adopted through, or nothing
/// where the link is one adoption would refuse. The planner asks this so a
/// hand-made sharing layout — one real folder, several tools reading it
/// through links — is offered the exit that works instead of being called
/// a dead end.
pub(crate) fn link_target(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    link: &Path,
) -> Option<PathBuf> {
    shared_at(env, scope, kind, name, link).map(|s| s.target)
}

/// The ops that take over a shared folder: capture its bytes into the
/// local source, move the folder itself to the trash — bound to the exact
/// bytes just captured, so a folder that changed under the plan aborts the
/// apply (invariant 7) — and clear every link that read it, each bound to
/// the text it was written with. The follow-up apply re-renders the
/// canonical tree and the links, which is what restores the sharing.
pub(super) fn shared_capture_ops(
    name: &str,
    shared: &SharedTarget,
    local_item: &Path,
) -> Result<Vec<PlannedOp>> {
    let mut ops = Vec::new();
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
    ops.push(PlannedOp {
        description: format!("move the shared folder's content of {name} into the local source"),
        op: Op::WriteTree {
            root: local_item.to_path_buf(),
            files: crate::capture::read_tree(&shared.target)?,
            pre: Pre::Absent,
        },
    });
    ops.push(PlannedOp {
        description: format!(
            "trash the shared folder at {} (recoverable)",
            shared.target.display()
        ),
        op: Op::Trash {
            path: shared.target.clone(),
            pre: Pre::HashIs {
                hash: crate::hash::hash_tree(&shared.target)?,
            },
        },
    });
    for (link, raw) in &shared.links {
        ops.push(PlannedOp {
            description: format!("clear the link at {}", link.display()),
            op: Op::Trash {
                path: link.clone(),
                pre: Pre::SymlinkTo {
                    target: raw.clone(),
                },
            },
        });
    }
    Ok(ops)
}
