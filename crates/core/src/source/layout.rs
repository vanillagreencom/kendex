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
pub(super) fn flat_skills(sealed: &SealedSource, dir: &str) -> Result<Vec<String>> {
    let is_skill = |path: &std::path::Path| item_dir(sealed, ItemKind::Skill, path);
    nested_names(sealed, dir, &is_skill, |path| {
        path.file_name()?.to_str().map(str::to_owned)
    })
}

/// Whether this directory is an item of `kind` rather than a directory
/// holding some. Only a skill is stored as a directory; every other kind's
/// item is a file, so no directory is one.
fn item_dir(sealed: &SealedSource, kind: ItemKind, dir: &std::path::Path) -> bool {
    kind == ItemKind::Skill && sealed.is_file(&dir.join("SKILL.md"))
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
    let held = match sealed.is_dir(slot) {
        true => slot.to_path_buf(),
        // Nothing is stored inside an absent directory, and nothing is
        // stored inside a file — which is what every other kind's slot is.
        false => match crate::names::folding_sibling(slot) {
            Some(sibling) if sealed.is_dir(&sibling) => sibling,
            _ => return Ok(None),
        },
    };
    // Being the plain item makes the slot replaceable, not empty. Its own
    // `SKILL.md` and supporting files belong to the item the capture is
    // written over, so they are not occupants — but a namespaced item
    // stored under the same directory is a second item, and the write
    // takes it too. Which children are items is `item_dir`'s to say, the
    // same judge `flat_skills` lists them by.
    let replaceable = item_dir(sealed, kind, &held);
    // A read that could not be made is not an empty directory: reading one
    // as the other is how a guard deletes what it exists to protect.
    let occupant = sealed
        .list_dir(&held)?
        .into_iter()
        .find(|entry| !replaceable || item_dir(sealed, kind, entry));
    let Some(occupant) = occupant else {
        return Ok(None);
    };
    let occupant = sealed.relative(&occupant).unwrap_or(&occupant);
    Ok(Some(crate::names::shown(&occupant.display().to_string())))
}

pub(super) fn agent_stems(sealed: &SealedSource, dir: &str) -> Result<Vec<String>> {
    file_stems(sealed, dir, "md")
}

/// The item names one kind dir holds — every file with the kind's extension,
/// by stem, at the top level or one segment down.
fn file_stems(sealed: &SealedSource, dir: &str, ext: &str) -> Result<Vec<String>> {
    let is_item =
        |path: &std::path::Path| path.extension().is_some_and(|e| e == ext) && sealed.is_file(path);
    nested_names(sealed, dir, &is_item, |path| {
        path.file_stem()?.to_str().map(str::to_owned)
    })
}

/// The item names a fixed kind dir holds, by file stem.
pub(super) fn ext_stems(sealed: &SealedSource, dir: &str, ext: &str) -> Result<Vec<String>> {
    file_stems(sealed, dir, ext)
}

/// Every entry under `dir` that `is_item` accepts, plus every such entry one
/// level down named `<parent>/<leaf>`. `leaf` extracts the segment an entry
/// contributes (a directory name, or a file stem). A listed name is one that
/// installs — `find_item` refuses the rest, so listing them would draw only
/// dead rows and, for a deceptive name, one whose shown spelling is not the
/// name that lands on disk.
///
/// A directory that will not list is an error, never an empty listing:
/// what an unreadable directory costs is the calling surface's to decide,
/// and a listing that answers "nothing" has taken that decision for it.
fn nested_names(
    sealed: &SealedSource,
    dir: &str,
    is_item: &dyn Fn(&std::path::Path) -> bool,
    leaf: impl Fn(&std::path::Path) -> Option<String>,
) -> Result<Vec<String>> {
    // A kind dir the catalog does not have holds nothing, which is an
    // answer. One that is there and will not list is not.
    let dir = sealed.root().join(dir);
    if !dir.is_dir() {
        return Ok(Vec::new());
    }
    let mut names = Vec::new();
    for entry in sealed.list_dir(&dir)? {
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
        {
            for child in sealed.list_dir(&entry)? {
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
    Ok(names)
}
