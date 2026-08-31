//! Reading item names out of a declared-layout catalog's fixed directories.
//! A listed name is always one that installs — `find_item` refuses the rest —
//! so a deceptive or otherwise unusable name is never drawn as a dead row.
//!
//! Names nest one level. A `plugin/item` name — a plugin-registry package
//! detached into the local source — is stored at `<dir>/plugin/item` and
//! listed as `plugin/item`, alongside a plain `<dir>/plugin` listed as
//! `plugin`: both, so neither hides the other. Depth stops at two segments
//! (one `/`), which is exactly what `names::item_problem` admits, so directory
//! traversal never doubles as a deeper identity encoding.

use std::path::PathBuf;

use crate::error::Result;
use crate::model::ItemKind;
use crate::source_read::SealedSource;

/// The fixed directory and extension a declared-layout catalog keeps one of
/// the file-per-item kinds in. Only those kinds have one.
pub(super) fn fixed_kind_dir(kind: ItemKind) -> (&'static str, &'static str) {
    match kind {
        ItemKind::Hook => ("hooks", "sh"),
        ItemKind::Command => ("commands", "md"),
        ItemKind::McpServer => ("mcp", "toml"),
        _ => unreachable!("only file-per-item kinds live in a fixed dir"),
    }
}

/// The skills one explicit catalog dir holds — a directory carrying `SKILL.md`,
/// at the top level (`gh`) or one segment down (`plugin/item`).
pub(super) fn flat_skills(sealed: &SealedSource, dir: &str) -> Vec<String> {
    let is_skill = |path: &std::path::Path| item_dir(sealed, ItemKind::Skill, path);
    nested_names(sealed, dir, &is_skill, |path| {
        path.file_name()?.to_str().map(str::to_owned)
    })
}

/// Whether this directory is an item of `kind` rather than a directory
/// holding some. Only a skill is stored as a directory; every other kind's
/// item is a file, so no directory is one.
///
/// The reading for a listing, which draws no row for a child it cannot
/// probe. The guard asks [`stored_item`] instead.
fn item_dir(sealed: &SealedSource, kind: ItemKind, dir: &std::path::Path) -> bool {
    stored_item(sealed, kind, dir).unwrap_or(false)
}

/// The same question with its third answer kept: a directory can be listed
/// without being traversable, so the probe into a child can fail while the
/// item it holds is on disk and about to be trashed. The guard below asks
/// this one, and every question it asks answers yes, no, or an error.
fn stored_item(sealed: &SealedSource, kind: ItemKind, dir: &std::path::Path) -> Result<bool> {
    Ok(kind == ItemKind::Skill && sealed.file_at(&dir.join("SKILL.md"))?)
}

/// `target` spelled the way its parent stores it — the exact name when the
/// parent holds it, a folding neighbour otherwise, `None` when neither. A
/// folding volume hands one directory back under every spelling of its
/// name, so a path built from a caller's spelling can name a real directory
/// the disk stores under some other string, and a person sent to look at
/// the caller's spelling will not find it there.
///
/// Read through the sealed reader, so the scan carries the same containment
/// and the same entry bound every other read of a source does: a parent
/// past the bound is refused here rather than scanned, and the adoption
/// stops instead of writing into a source discovery will later refuse.
fn stored_spelling(sealed: &SealedSource, target: &std::path::Path) -> Result<Option<PathBuf>> {
    let (Some(parent), Some(leaf)) = (target.parent(), target.file_name().and_then(|l| l.to_str()))
    else {
        return Ok(None);
    };
    // A parent that is not there holds nothing, which is an answer. One
    // that is there and will not say is not.
    if !sealed.dir_at(parent)? {
        return Ok(None);
    }
    let folded = crate::names::fold(leaf);
    let mut folding = None;
    for entry in sealed.all_entries(parent)? {
        let Some(name) = entry.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if name == leaf {
            return Ok(Some(target.to_path_buf()));
        }
        if folding.is_none() && crate::names::fold(name) == folded {
            folding = Some(entry);
        }
    }
    Ok(folding)
}

/// What the local source already stores in a plain name's slot that the
/// capture would take with it, named as the path it sits at — or nothing,
/// when the slot is free for the capture: the directory is absent, or it
/// holds only the plain item the capture replaces.
///
/// The disk answers this, never a catalog listing. A listing says what a
/// source OFFERS, and every rule it is drawn through — an unusable catalog
/// offering nothing, a name filter, the support-directory names above —
/// reads as an empty slot over a directory that is holding content. What
/// the capture would write over is a question about bytes.
///
/// A folding sibling is the same slot: a volume that hands `Data-Science`
/// and `data-science` to one directory keeps the stored item where the
/// plain name is asking to write.
pub(super) fn stored_in_slot(
    sealed: &SealedSource,
    kind: ItemKind,
    slot: &std::path::Path,
) -> Result<Option<String>> {
    // The disk's spelling of the slot, never the caller's: on a folding
    // volume the slot names the stored directory while spelling it some
    // other way, and every path this returns is a path a person is being
    // sent to look at. Nothing is stored inside an absent directory, and
    // nothing is stored inside a file — which is what every other kind's
    // slot is.
    let Some(held) = stored_spelling(sealed, slot)? else {
        return Ok(None);
    };
    if !sealed.dir_at(&held)? {
        return Ok(None);
    }
    // A read that could not be made is not an empty directory, and a probe
    // that could not be made is not a child that is no item: reading either
    // one as the other is how a guard deletes what it exists to protect.
    let occupant = match stored_item(sealed, kind, &held)? {
        // Being the plain item makes the slot replaceable, not empty. Its
        // own `SKILL.md` and supporting files belong to the item the
        // capture is written over, so they are not occupants — but an item
        // stored under the same directory is a second item, and the write
        // takes it too.
        true => descendant_item(sealed, kind, &held)?,
        // A slot that is not the item holds nothing the capture may take,
        // so any entry at all is an occupant.
        false => sealed.all_entries(&held)?.into_iter().next(),
    };
    let Some(occupant) = occupant else {
        return Ok(None);
    };
    // Text, not a path handed back to the operating system, so
    // `paths::slashed` spells it rather than the platform's separator.
    let occupant = sealed.relative(&occupant).unwrap_or(&occupant);
    Ok(Some(crate::names::shown(&crate::paths::slashed(occupant))))
}

/// The shallowest item stored anywhere under a replaceable slot, or
/// nothing when the slot holds only the plain item's own files. Which
/// directory is an item is [`stored_item`]'s to say, the same judge
/// `flat_skills` lists them by.
///
/// Immediate children are not the whole slot. A catalog that declares its
/// own directories stores its items under one of them, and that directory
/// can itself be a plain name's slot: with `skills/data-science` declared,
/// `foo/eda` is stored at `skills/data-science/foo/eda`, where the only
/// child of the slot is `foo`, which is no item. How deep the items sit is
/// the catalog's to choose, so the search descends instead of reading the
/// tables that chose it — a table says what a source OFFERS, and both the
/// display exclusions it is drawn through and an unusable one offering
/// nothing read as an empty slot over a directory holding content.
///
/// The search is bounded by the entries it looks at rather than by depth,
/// which leaves a directory's whole width free to multiply at every level.
/// The budget is the tree bound: a slot holding more entries than kendex
/// will read out of one tree holds more than it can render back. Past it
/// the search has not finished looking, which is not the same answer as
/// having found nothing, and this is a guard — so it refuses.
fn descendant_item(
    sealed: &SealedSource,
    kind: ItemKind,
    slot: &std::path::Path,
) -> Result<Option<PathBuf>> {
    let budget = crate::source_read::TREE_BOUND.files;
    let mut left = budget;
    // Breadth first: the occupant named is a path a person is sent to look
    // at, and the shallowest one is the nearest to the name they typed.
    let mut pending = std::collections::VecDeque::from([slot.to_path_buf()]);
    while let Some(dir) = pending.pop_front() {
        for entry in sealed.all_entries(&dir)? {
            let Some(remaining) = left.checked_sub(1) else {
                return Err(crate::error::CoreError::SourceEscape {
                    path: slot.to_path_buf(),
                    reason: format!(
                        "more than {budget} entries under one slot — \
                         cannot tell what is stored there"
                    ),
                });
            };
            left = remaining;
            // Only a directory is a skill and only a directory holds one,
            // so an entry that is neither is no item and no place to keep
            // looking. The probe is fallible all the same: an entry the
            // filesystem will not describe is not an entry that is no
            // directory.
            if !sealed.dir_at(&entry)? {
                continue;
            }
            if stored_item(sealed, kind, &entry)? {
                return Ok(Some(entry));
            }
            pending.push_back(entry);
        }
    }
    Ok(None)
}

pub(super) fn agent_stems(sealed: &SealedSource, dir: &str) -> Vec<String> {
    file_stems(sealed, dir, "md")
}

/// The item names one kind dir holds — every file with the kind's extension,
/// by stem, at the top level or one segment down.
pub(super) fn file_stems(sealed: &SealedSource, dir: &str, ext: &str) -> Vec<String> {
    let is_item =
        |path: &std::path::Path| path.extension().is_some_and(|e| e == ext) && sealed.is_file(path);
    nested_names(sealed, dir, &is_item, |path| {
        path.file_stem()?.to_str().map(str::to_owned)
    })
}

/// Every entry under `dir` that `is_item` accepts, plus every such entry one
/// level down named `<parent>/<leaf>`. `leaf` extracts the segment an entry
/// contributes (a directory name, or a file stem). A listed name is one that
/// installs — `find_item` refuses the rest, so listing them would draw only
/// dead rows and, for a deceptive name, one whose shown spelling is not the
/// name that lands on disk.
///
/// A directory this cannot read draws no rows for that directory, and the
/// rest of the listing still draws: a listing says what a source offers,
/// and one unreadable sibling must not take the readable items of the same
/// kind out of `add --all` and out of place resolution. Nothing deciding
/// what a write would destroy asks this — that reads the disk, through
/// `SealedSource::all_entries`, where a refused read is an error.
fn nested_names(
    sealed: &SealedSource,
    dir: &str,
    is_item: &dyn Fn(&std::path::Path) -> bool,
    leaf: impl Fn(&std::path::Path) -> Option<String>,
) -> Vec<String> {
    let Ok(entries) = sealed.readable_entries(&sealed.root().join(dir)) else {
        return Vec::new();
    };
    let mut names = Vec::new();
    for entry in entries {
        if is_item(&entry)
            && let Some(name) = leaf(&entry)
        {
            names.push(name);
        }
        if sealed.is_dir(&entry)
            && let Some(parent) = entry.file_name().and_then(|n| n.to_str())
            // A kind dir's support directories hold the items' own test
            // suites and fixtures, the same vocabulary a skill tree marks
            // as supporting — files there are about the items, not items.
            && !matches!(parent, "tests" | "test" | "fixtures" | "testdata")
            && let Ok(children) = sealed.readable_entries(&entry)
        {
            for child in children {
                if is_item(&child)
                    && let Some(leaf) = leaf(&child)
                {
                    names.push(format!("{parent}/{leaf}"));
                }
            }
        }
    }
    names.retain(|name| crate::names::item_problem(name).is_none());
    names.sort();
    names.dedup();
    names
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sealed(root: &std::path::Path) -> SealedSource {
        std::fs::create_dir_all(root).unwrap();
        SealedSource::open(root).unwrap()
    }

    /// The step a folding volume turns on: `Data-Science` is what the disk
    /// holds, so that is what a person asking for `data-science` is told,
    /// whatever spelling reached the directory.
    #[test]
    fn a_slot_is_spelled_the_way_its_parent_stores_it() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("catalog");
        let sealed = sealed(&root);
        let parent = root.join("skills");
        let asked = parent.join("data-science");
        std::fs::create_dir_all(parent.join("Data-Science")).unwrap();
        assert_eq!(
            stored_spelling(&sealed, &asked).unwrap(),
            Some(parent.join("Data-Science"))
        );
        assert_eq!(
            stored_spelling(&sealed, &parent.join("handmade")).unwrap(),
            None
        );
        // A directory that is not there holds nothing, and saying so is not
        // a swallow: an adoption into a local source with no kind dir yet
        // has to land.
        assert_eq!(
            stored_spelling(&sealed, &root.join("absent/handmade")).unwrap(),
            None
        );

        // A volume keeping the two names apart stores an exact entry, and
        // that is the name a write lands on; one that folds them has the
        // single directory it was created under. The parent answers both.
        let stored = match std::fs::create_dir(&asked) {
            Ok(()) => "data-science",
            Err(_) => "Data-Science",
        };
        assert_eq!(
            stored_spelling(&sealed, &asked).unwrap(),
            Some(parent.join(stored))
        );
    }

    /// A parent that is searchable but not listable — POSIX mode 0311, or
    /// an ACL — keeps the slot and everything under it reachable while the
    /// scan returns nothing. The error is the answer; `None` here is a slot
    /// reported free while it holds what the caller would write over.
    #[cfg(unix)]
    #[test]
    fn a_parent_that_will_not_enumerate_errors_rather_than_reading_empty() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("catalog");
        let sealed = sealed(&root);
        let parent = root.join("skills");
        std::fs::create_dir_all(parent.join("data-science")).unwrap();
        std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o311)).unwrap();
        // Root reads any directory whatever its mode, so there the denial
        // under test does not exist and the exact spelling is the answer.
        let denied = std::fs::read_dir(&parent).is_err();
        let asked = stored_spelling(&sealed, &parent.join("data-science"));
        std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o755)).unwrap();

        match denied {
            true => assert!(
                matches!(asked, Err(crate::error::CoreError::Io { .. })),
                "{asked:?}"
            ),
            false => assert_eq!(asked.unwrap(), Some(parent.join("data-science"))),
        }
    }
}
