//! Adopting a skill without copying it anywhere.
//!
//! A project's skills already live in one shared tree that every tool but
//! Claude Code reads. Taking over a skill somebody wrote by hand is
//! therefore a move, not a capture: the real directory goes to
//! `.agents/skills/<name>`, the place it was read from becomes a relative
//! link to it, and the declaration names the `in-place` source — the tree
//! itself. Nothing is kept in a second, hidden copy, so there is no copy to
//! drift from, and a refresh has structure and links to maintain but no
//! content of its own to write.
//!
//! Agents keep the capture: their file is rendered per tool (Markdown
//! dialects for some, TOML for Codex), so there is no one tree several
//! tools could read, and a single home would have to be a copy anyway.

use std::path::{Path, PathBuf};

use crate::apply::{Description, Op, PlannedOp, Pre};
use crate::error::{CoreError, Result};
use crate::model::{ItemKind, Scope};

/// The file that makes a directory a skill.
const MARKER: &str = "SKILL.md";

/// Where this item's content of record lives when it is its own source, or
/// nothing for a kind or scope that has no shared tree to be in place in.
pub(super) fn home(scope: &Scope, kind: ItemKind, name: &str) -> Option<PathBuf> {
    if kind != ItemKind::Skill {
        return None;
    }
    // A namespaced name is stored under one flattened leaf — `plugin/item`
    // reaches disk as `plugin__item` — so the tree does not spell the name
    // it would have to be looked up by. It cannot be its own source, and it
    // keeps the capture the local source has always given it.
    if crate::names::split(name).is_some() {
        return None;
    }
    let root = crate::source::inplace_source_root(scope)?;
    Some(
        root.join("skills")
            .join(crate::harness::canonical_name(name)),
    )
}

/// Why the shared tree cannot hold this item's content, in words for the
/// person who typed the name. Asked before a byte is planned and again by
/// every surface that draws the offer, so the two can never disagree.
pub(super) fn unreachable(home: &Path) -> Result<Option<String>> {
    // The directories above it, not the leaf: the leaf is what adoption is
    // about to replace, and a link sitting there is the shape this path
    // exists to settle. What has to be real is the way down to it — bytes
    // written past a link are bytes the sealed reader will not read back,
    // so the declaration would name content nothing can resolve.
    let (Some(parent), Some(root)) = (home.parent(), home.parent().and_then(Path::parent)) else {
        return Ok(None);
    };
    if !root.is_dir() {
        return Ok(None);
    }
    let sealed = crate::source_read::SealedSource::open(root)?;
    Ok(sealed
        .contained(parent)
        .err()
        .map(|escape| format!("the shared .agents tree cannot hold it there — {escape}")))
}

/// The ops that put the item's one real directory at `home` and clear
/// every other place a copy of it was sitting.
///
/// No link is written here. The declaration this plan carries is what makes
/// the harness positions kendex's to write, and the apply that follows
/// renders them — as relative links to the tree that just landed. Writing
/// them here would be the same links, planned by the half of the system
/// that does not own them.
pub(super) fn relocate_ops(
    name: &str,
    held: &[PathBuf],
    links: &[(PathBuf, PathBuf)],
    home: &Path,
) -> Result<Vec<PlannedOp>> {
    // A skill is a directory holding its marker — that is what the shared
    // tree has to end up with, and what a later pass reads back to find the
    // item. One file wearing the name is somebody's content in an awkward
    // shape: moving it would leave a declaration pointing at nothing.
    if let Some(wrong) = held.iter().find(|path| !path.join(MARKER).is_file()) {
        return Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            // Text the reader is shown, not a path going back to the
            // operating system, so `paths::slashed` spells it.
            source_name: format!(
                "{} is not a folder holding a {MARKER}",
                crate::paths::slashed(wrong)
            ),
        });
    }
    let mut ops = Vec::new();
    for (link, raw) in links {
        ops.push(PlannedOp {
            description: Description::around("clear the link at ", ""),
            op: Op::Trash {
                absent_is_done: false,
                path: link.clone(),
                pre: Pre::SymlinkTo {
                    target: raw.clone(),
                },
            },
        });
    }
    // The copy already at the home is the one to keep: moving another over
    // it would trash and rewrite the same path in one plan, and the second
    // op would find the first one's work and fail its precondition.
    let cleared = links.iter().any(|(link, _)| link == home);
    let in_place = !cleared && held.iter().any(|path| path == home);
    let from = match in_place {
        true => None,
        false => held.first(),
    };
    if let Some(from) = from {
        if !cleared && (home.exists() || home.is_symlink()) {
            ops.push(PlannedOp {
                description: Description::around("trash what is already at ", ""),
                op: Op::Trash {
                    absent_is_done: false,
                    path: home.to_path_buf(),
                    pre: Pre::HashIs {
                        hash: crate::hash::hash_tree(home)?,
                    },
                },
            });
        }
        // A move, not a copy: the entries the plan showed are the entries
        // that land, bound as they sit — `hash_tree` follows links, so a
        // directory swapped for a link to the same bytes between plan and
        // apply would move the wrong object.
        ops.push(PlannedOp {
            description: format!("move {name} into the shared .agents tree").into(),
            op: Op::Rename {
                from_pre: Pre::tree_as_is(from)?,
                to_pre: Pre::Absent,
                from: from.clone(),
                to: home.to_path_buf(),
            },
        });
    }
    for path in held {
        if Some(path) == from || path == home {
            continue;
        }
        // Bound to what `look` proved equal to the copy being kept. `Any`
        // would trash whatever arrived at that position after the plan was
        // read — including content nobody compared with anything.
        ops.push(PlannedOp {
            description: Description::around("trash the second copy at ", ""),
            op: Op::Trash {
                absent_is_done: false,
                path: path.clone(),
                pre: Pre::tree_as_is(path)?,
            },
        });
    }
    Ok(ops)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_project_skill_has_a_home_of_its_own() {
        let scope = Scope::Project {
            root: PathBuf::from("/w/proj"),
        };
        assert_eq!(
            home(&scope, ItemKind::Skill, "release"),
            Some(PathBuf::from("/w/proj/.agents/skills/release"))
        );
        assert_eq!(home(&scope, ItemKind::Agent, "release"), None);
        assert_eq!(home(&scope, ItemKind::Skill, "data-science/eda"), None);
        assert_eq!(home(&Scope::Global, ItemKind::Skill, "release"), None);
    }

    /// A tool whose own place is the shared tree has nothing to move, and a
    /// rename onto itself would fail its own precondition.
    #[test]
    fn content_already_at_home_plans_no_move() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let home = tmp.path().join(".agents/skills/release");
        std::fs::create_dir_all(&home).expect("home");
        std::fs::write(home.join(MARKER), "---\nname: release\n---\n").expect("marker");
        let ops = relocate_ops("release", std::slice::from_ref(&home), &[], &home).expect("ops");
        assert!(ops.is_empty(), "{}", ops.len());
    }

    /// One file wearing the name is content in an awkward shape: the move
    /// would leave a declaration pointing at something no pass can read as
    /// a skill.
    #[test]
    fn a_file_where_the_folder_goes_is_refused() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let held = tmp.path().join(".claude/skills/release");
        std::fs::create_dir_all(held.parent().expect("parent")).expect("dirs");
        std::fs::write(&held, "not a folder").expect("file");
        let home = tmp.path().join(".agents/skills/release");
        assert!(relocate_ops("release", std::slice::from_ref(&held), &[], &home).is_err());
    }
}
