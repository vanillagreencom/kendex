use std::fs;
use std::path::{Path, PathBuf};

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
    // Adoption takes what kendex did not write. A position it did write is
    // already looked after, and capturing it would move an installation
    // into the local source and rewrite the declaration around it — a
    // catalog-tracked item quietly becoming a fork of itself. The page a
    // keep was clicked on can be a minute old, and something else can have
    // installed the item in between.
    //
    // A lock that cannot be read is not an empty one: read as empty, every
    // installation on this machine would look like a stranger's files.
    let owned: std::collections::BTreeSet<PathBuf> =
        crate::lock::load(&crate::lock::lock_path(env, scope))?
            .entries
            .values()
            .flat_map(|entry| super::owned::installed(env, scope, entry).files)
            .collect();
    // Where a position leads, not only where it sits: a link somebody made
    // can point at another item's installation, and the capture moves what
    // it points at.
    // Anywhere an installation lives, not only its exact root: a link into
    // a folder inside a managed skill, or at a folder holding managed
    // installs, moves them just the same.
    let managed = |path: &Path| {
        let at = path.canonicalize();
        let touches = |ours: &PathBuf, at: &Path| ours.starts_with(at) || at.starts_with(ours);
        owned
            .iter()
            .any(|ours| touches(ours, path) || at.as_ref().is_ok_and(|at| touches(ours, at)))
    };
    if let Some((_, held)) = positions.iter().find(|(_, path)| managed(path)) {
        return Err(already_managed(name, held));
    }

    // The offer withholds this shape, and so does the verb: a reader can
    // name the item directly, and taking one spelling while the other
    // stays leaves a file a later switch reads as kendex's own.
    if let Some((_, at)) = positions.iter().find(|(_, at)| both_spellings(kind, at)) {
        return Err(CoreError::TogglesDiffer {
            name: name.to_owned(),
            detail: crate::names::shown(&at.display().to_string()),
        });
    }

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

/// Where in the scope's local source the kept content lands. Read wherever
/// a surface asks whether adoption could take a position, so the question
/// and the answer are never two different rules.
fn local_item_path(env: &Env, scope: &Scope, kind: ItemKind, name: &str) -> Result<PathBuf> {
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

fn already_managed(name: &str, path: &Path) -> CoreError {
    CoreError::AlreadyManaged {
        name: name.to_owned(),
        path: crate::names::shown(&path.display().to_string()),
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

// Adopting a shared folder through the link a tool reads it by: the
// boundary that decides what a link may be adopted through, and the ops
// that take the folder over without breaking the other tools reading it.

/// A live symlink's resolved target, once it has passed the boundary: the
/// real folder whose content is being adopted, and every native link (with
/// the text it was written with) that resolves to it.
struct SharedTarget {
    target: PathBuf,
    /// Link path → the target exactly as the link spells it, so the
    /// removal's precondition catches a link repointed between plan and
    /// apply.
    links: Vec<(PathBuf, PathBuf)>,
    /// Every tool whose native link reads this folder.
    harnesses: Vec<HarnessId>,
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
fn shared_target(
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
    if local_item.starts_with(&target) {
        return Err(refuse());
    }

    let mut links = Vec::new();
    let mut harnesses = Vec::new();
    for h in HarnessId::ALL {
        let Some(dir) = native_dir(env, scope, h, ItemKind::Skill) else {
            continue;
        };
        let candidate = dir.join(crate::harness::rendered_name(h, name));
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

/// The folder a link at this position could be adopted through, or nothing
/// where the link is one adoption would refuse. The planner asks this so a
/// hand-made sharing layout — one real folder, several tools reading it
/// through links — is offered the exit that works instead of being called
/// a dead end, and asks it through the same boundary the adoption itself
/// applies, so the offer and the action can never drift apart.
/// Every tool adoption will act on for this position. A folder shared by
/// hand is read by whoever links at it, declared or not, and taking it
/// over clears each of those links — so a surface offering the move has to
/// name them all, or it acts on a tool it never mentioned.
pub(super) fn shared_tools(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    link: &Path,
) -> Option<Vec<HarnessId>> {
    let points_to = fs::read_link(link).ok()?;
    let local_item = local_item_path(env, scope, kind, name).ok()?;
    let shared = shared_target(env, scope, kind, name, link, points_to, &local_item).ok()?;
    Some(shared.harnesses)
}

pub(super) fn link_target(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    link: &Path,
) -> Option<PathBuf> {
    let points_to = fs::read_link(link).ok()?;
    let local_item = local_item_path(env, scope, kind, name).ok()?;
    let shared = shared_target(env, scope, kind, name, link, points_to, &local_item).ok()?;
    Some(shared.target)
}

/// The ops that take over a shared folder: capture its bytes into the
/// local source, move the folder itself to the trash — bound to the exact
/// bytes just captured, so a folder that changed under the plan aborts the
/// apply (invariant 7) — and clear every link that read it, each bound to
/// the text it was written with. The follow-up apply re-renders the
/// canonical tree and the links, which is what restores the sharing.
fn shared_capture_ops(
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
            files: read_tree(&shared.target)?,
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

// What a capture may read: the walk that turns a folder on disk into the
// bytes adoption writes into the local source, and the budget that stops a
// link at somebody's home directory becoming a memory problem.

/// Far beyond any real skill, but a hard stop before a link at a huge
/// folder turns a capture into a memory problem. Fail-loud: the error
/// names the file that broke the budget.
const MAX_CAPTURE_FILES: usize = 2000;
const MAX_CAPTURE_BYTES: u64 = 100 * 1024 * 1024;

pub(crate) fn read_tree(root: &Path) -> Result<Vec<(PathBuf, Vec<u8>)>> {
    fn walk(
        dir: &Path,
        rel: &Path,
        files: &mut Vec<(PathBuf, Vec<u8>)>,
        bytes: &mut u64,
    ) -> Result<()> {
        for entry in fs::read_dir(dir).map_err(|e| CoreError::io(dir, e))? {
            // A per-entry read error is not silently skipped: dropping it
            // would capture an incomplete tree and then trash the
            // original, losing content the caller asked to keep.
            let entry = entry.map_err(|e| CoreError::io(dir, e))?;
            let path = entry.path();
            let Some(name) = path.file_name() else {
                continue;
            };
            let rel = rel.join(name);
            // A link is not plain content: following it would read whatever
            // it points at into the capture under this tree's name. Rather
            // than silently drop it (and then trash the original), refuse —
            // nothing the user asked to keep is lost without a word.
            if path.is_symlink() {
                return Err(CoreError::ForeignSymlink {
                    points_to: fs::read_link(&path).unwrap_or_default(),
                    target: path,
                });
            }
            if path.is_dir() {
                walk(&path, &rel, files, bytes)?;
                continue;
            }
            // A FIFO would block the read forever and a device is not
            // content; capturing arbitrary user folders means saying so
            // instead of hanging.
            let shape = fs::symlink_metadata(&path).map_err(|e| CoreError::io(&path, e))?;
            if !shape.is_file() {
                return Err(CoreError::io(
                    &path,
                    std::io::Error::other("not a regular file — adopt captures plain files only"),
                ));
            }
            // The budget is spent on what was read, never on what the
            // metadata said: a file that grows between the two would leave
            // every file after it a budget that no longer exists, and the
            // bound would hold only for a tree that sat still. So the
            // reader is capped and the total counts the bytes it returned.
            let room = MAX_CAPTURE_BYTES.saturating_sub(*bytes);
            let mut body = Vec::new();
            fs::File::open(&path)
                .and_then(|file| {
                    use std::io::Read;
                    file.take(room + 1).read_to_end(&mut body)
                })
                .map_err(|e| CoreError::io(&path, e))?;
            *bytes += body.len() as u64;
            if files.len() >= MAX_CAPTURE_FILES || body.len() as u64 > room {
                return Err(CoreError::io(
                    &path,
                    std::io::Error::other(format!(
                        "this folder is bigger than adopt will capture (over {MAX_CAPTURE_FILES} files or {} MB)",
                        MAX_CAPTURE_BYTES / (1024 * 1024)
                    )),
                ));
            }
            files.push((rel, body));
        }
        Ok(())
    }
    let mut files = Vec::new();
    let mut bytes = 0;
    walk(root, Path::new(""), &mut files, &mut bytes)?;
    Ok(files)
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

// Where a tool reads an item, and which spelling of the toggled pair is
// the one on disk. The question a surface asks and the place adoption
// reads are answered here together, so an offer never names a position
// the capture will not find.

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

/// Whether both spellings of the toggled pair hold content. Keeping would
/// take one and leave the other, and a later switch reads what is left as
/// kendex's own — so the reader is asked to settle it first rather than
/// offered a move that takes half of it.
pub(super) fn both_spellings(kind: ItemKind, at: &Path) -> bool {
    match kind {
        ItemKind::Skill => there(&at.join("SKILL.md")) && there(&at.join("SKILL.md.disabled")),
        _ => there(at) && there(&crate::engine::file_plan::toggle_sibling(at)),
    }
}

/// Whether this tool has something adoption can keep. A tool with an empty
/// position is never named in an offer: adoption works at that position and
/// nowhere else, and the folder a link points at is reached through the
/// tool whose own place is the link.
///
/// A skill is a folder holding a `SKILL.md` — that is what the local source
/// finds again afterwards. Kept without one, the folder goes to the trash,
/// the declaration is rewritten around a source that has nothing to give,
/// and the apply that follows installs nothing: the reader is told their
/// files were kept and they are gone.
pub fn can_keep_for(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
) -> bool {
    supports(kind)
        && position(env, scope, kind, name, harness).is_some_and(|path| {
            !both_spellings(kind, &path)
                && match kind {
                    // The marker is a file the capture reads. A directory
                    // wearing its name is not one, and taking the tree
                    // would trash the original for a source that has
                    // nothing to give back.
                    ItemKind::Skill => path.join("SKILL.md").is_file(),
                    _ => there(&path),
                }
        })
}

fn there(path: &Path) -> bool {
    path.exists() || path.is_symlink()
}

#[cfg(test)]
mod tests;
