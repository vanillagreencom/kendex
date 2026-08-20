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
    let is_skill = |path: &std::path::Path| sealed.is_file(&path.join("SKILL.md"));
    nested_names(sealed, dir, &is_skill, |path| {
        path.file_name()?.to_str().map(str::to_owned)
    })
}

pub(super) fn agent_stems(sealed: &SealedSource, dir: &str) -> Vec<String> {
    file_stems(sealed, dir, "md")
}

/// The item names one kind dir holds — every file with the kind's extension,
/// by stem, at the top level or one segment down.
fn file_stems(sealed: &SealedSource, dir: &str, ext: &str) -> Vec<String> {
    let is_item =
        |path: &std::path::Path| path.extension().is_some_and(|e| e == ext) && sealed.is_file(path);
    nested_names(sealed, dir, &is_item, |path| {
        path.file_stem()?.to_str().map(str::to_owned)
    })
}

/// The item names a fixed kind dir holds, by file stem.
pub(super) fn ext_stems(sealed: &SealedSource, dir: &str, ext: &str) -> Vec<String> {
    file_stems(sealed, dir, ext)
}

/// Every entry under `dir` that `is_item` accepts, plus every such entry one
/// level down named `<parent>/<leaf>`. `leaf` extracts the segment an entry
/// contributes (a directory name, or a file stem). A listed name is one that
/// installs — `find_item` refuses the rest, so listing them would draw only
/// dead rows and, for a deceptive name, one whose shown spelling is not the
/// name that lands on disk.
fn nested_names(
    sealed: &SealedSource,
    dir: &str,
    is_item: &dyn Fn(&std::path::Path) -> bool,
    leaf: impl Fn(&std::path::Path) -> Option<String>,
) -> Vec<String> {
    let Ok(entries) = sealed.list_dir(&sealed.root().join(dir)) else {
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
            && let Ok(children) = sealed.list_dir(&entry)
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
