//! How a link spells its way to the tree it reads.
//!
//! A link inside a project is committed with the project, so its text has to
//! resolve on the machine that clones it — an absolute path names a home
//! directory nobody else has. Inside one root the answer is a path relative
//! to the link's own parent; anywhere else (a project link into the app's
//! own folder, a global install) there is nothing shared to be relative to
//! and the absolute path is the only spelling that reaches.

use std::path::{Component, Path, PathBuf};

/// The text a link at `link` should hold to reach `target`.
///
/// `root` is the tree the pair has to survive being moved as a whole —
/// a project root. Both ends must sit inside it, and neither may spell
/// itself with `..`: a lexical answer for a path that is already lexically
/// ambiguous would point somewhere nobody named.
pub(crate) fn spelling(root: Option<&Path>, target: &Path, link: &Path) -> PathBuf {
    let absolute = || target.to_path_buf();
    let (Some(root), Some(parent)) = (root, link.parent()) else {
        return absolute();
    };
    if !target.starts_with(root) || !parent.starts_with(root) {
        return absolute();
    }
    if [target, parent, root]
        .iter()
        .any(|path| has_parent_ref(path))
    {
        return absolute();
    }
    relative(parent, target).unwrap_or_else(absolute)
}

/// Whether `points_to` — the text read back from the link at `link` — names
/// `target`. Both spellings are accepted: an install written before the
/// relative one holds the absolute path, and it reaches the same directory
/// on the machine that wrote it.
pub(crate) fn points_at(link: &Path, points_to: &Path, target: &Path) -> bool {
    if points_to == target {
        return true;
    }
    resolved(link, points_to).is_some_and(|resolved| resolved == target)
}

/// Where a link's text leads, read against the link's own parent, or
/// nothing where the text escapes above the filesystem root.
pub(crate) fn resolved(link: &Path, points_to: &Path) -> Option<PathBuf> {
    if points_to.is_absolute() {
        return Some(points_to.to_path_buf());
    }
    normalize(&link.parent()?.join(points_to))
}

fn has_parent_ref(path: &Path) -> bool {
    path.components().any(|c| c == Component::ParentDir)
}

/// `target` seen from `base`, both absolute and free of `..`.
fn relative(base: &Path, target: &Path) -> Option<PathBuf> {
    let mut base = base.components().peekable();
    let mut target = target.components().peekable();
    while base.peek().is_some() && base.peek() == target.peek() {
        base.next();
        target.next();
    }
    let mut out = PathBuf::new();
    for component in base {
        // Only a normal component can be stepped out of; a prefix or the
        // root reaching here means the two paths never shared an ancestor.
        match component {
            Component::Normal(_) => out.push(".."),
            _ => return None,
        }
    }
    out.extend(target);
    (!out.as_os_str().is_empty()).then_some(out)
}

/// A path with `.` dropped and `..` folded lexically. `None` where the `..`
/// components climb past the root, which no real path does.
fn normalize(path: &Path) -> Option<PathBuf> {
    let mut out: Vec<Component> = Vec::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => match out.last() {
                Some(Component::Normal(_)) => {
                    out.pop();
                }
                Some(Component::RootDir | Component::Prefix(_)) => {}
                _ => return None,
            },
            other => out.push(other),
        }
    }
    Some(out.iter().collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(text: &str) -> PathBuf {
        PathBuf::from(text)
    }

    #[test]
    fn a_link_inside_the_project_is_spelled_from_its_own_parent() {
        let root = p("/w/proj");
        assert_eq!(
            spelling(
                Some(&root),
                &p("/w/proj/.agents/skills/deploy"),
                &p("/w/proj/.claude/skills/deploy"),
            ),
            p("../../.agents/skills/deploy"),
        );
    }

    /// The link that names a machine: nothing shared to be relative to.
    #[test]
    fn a_link_out_of_the_root_keeps_the_absolute_path() {
        let root = p("/w/proj");
        let target = p("/home/u/.local/share/kendex/skills/deploy");
        assert_eq!(
            spelling(Some(&root), &target, &p("/w/proj/.claude/skills/deploy")),
            target,
        );
        assert_eq!(
            spelling(None, &target, &p("/home/u/.claude/skills/deploy")),
            target
        );
    }

    /// A `..` anywhere makes the lexical answer a guess, and a guess here
    /// is a link pointing at content nobody named.
    #[test]
    fn a_dotdot_in_either_end_keeps_the_absolute_path() {
        let root = p("/w/proj");
        let target = p("/w/proj/../proj/.agents/skills/deploy");
        assert_eq!(
            spelling(Some(&root), &target, &p("/w/proj/.claude/skills/deploy")),
            target
        );
    }

    #[test]
    fn both_spellings_name_the_same_tree() {
        let link = p("/w/proj/.claude/skills/deploy");
        let target = p("/w/proj/.agents/skills/deploy");
        assert!(points_at(&link, &target, &target));
        assert!(points_at(&link, &p("../../.agents/skills/deploy"), &target));
        assert!(!points_at(&link, &p("../../.agents/skills/other"), &target));
        assert!(!points_at(&link, &p("/elsewhere/deploy"), &target));
    }

    #[test]
    fn a_link_text_reads_against_its_own_parent() {
        let link = p("/w/proj/.claude/skills/deploy");
        assert_eq!(
            resolved(&link, &p("../../.agents/skills/deploy")),
            Some(p("/w/proj/.agents/skills/deploy")),
        );
        assert_eq!(resolved(&link, &p("/abs/x")), Some(p("/abs/x")));
    }
}
