//! Expanding a kind's configured catalog paths into the roots discovery
//! reads, and deciding whether each one is a root at all.
//!
//! A root is usable only when it is the ENTRY TYPE the kind reads from. An
//! existence test cannot answer that: a `skills` root that has become a
//! regular file exists, discovery skips it, and the empty inventory that
//! leaves behind reads as "the source ships no skills" — so every skill
//! locked against it is reported removed upstream with a `vstack remove`
//! beside it. Wrong type is UNREADABLE, never present-and-empty.

use super::CatalogKind;
use anyhow::{Context, Result};
use std::path::{Component, Path, PathBuf};

/// The item paths a kind's configured roots expand to, and what those roots
/// turned out to be.
#[derive(Debug)]
pub(super) struct ExpandedRoots {
    pub(super) paths: Vec<PathBuf>,
    /// Every configured root is present. A glob whose parent directory exists
    /// counts: it is a readable root that currently matches nothing, which is
    /// evidence the source ships no such item — not evidence the layout moved.
    ///
    /// This is an AND, never an OR: one readable root cannot vouch for a
    /// sibling that is missing, or the items the missing root used to supply
    /// would classify as removed upstream and `check` would tell the user to
    /// uninstall a still-valid install. A missing root instead makes the kind
    /// [`KindInventory::MissingRoot`](super::KindInventory::MissingRoot) —
    /// "inspect the source layout", which is the safe direction to be wrong in.
    ///
    /// An explicitly empty `[catalog]` list has no roots to check and so is
    /// vacuously present: an empty list is positive evidence the source ships
    /// no items of that kind. An ABSENT key is not empty — it expands to the
    /// kind's default root and fails this test when that root is gone.
    pub(super) all_roots_present: bool,
    /// `path: what was found` for every configured root that exists but is not
    /// something this kind can be read from. Nothing about the kind can be
    /// concluded from such a root — not even that it is empty — so a caller
    /// that classifies removals must report these instead.
    pub(super) unusable: Vec<String>,
    /// Roots already admitted, lexically normalized: two configured entries
    /// naming one directory are one root.
    seen: std::collections::HashSet<PathBuf>,
}

impl ExpandedRoots {
    pub(super) fn empty() -> Self {
        Self {
            paths: Vec::new(),
            all_roots_present: true,
            unusable: Vec::new(),
            seen: std::collections::HashSet::new(),
        }
    }

    /// The ONE way a path becomes a root discovery reads.
    ///
    /// Every producer arrives here — the literal entry, each match a glob
    /// yields, and the default root an absent `[catalog]` key expands to — so
    /// the entry-type rule cannot be skipped by a new source of roots the way
    /// glob matches once skipped it: nothing else can reach `paths`.
    fn admit(&mut self, path: PathBuf, kind: CatalogKind) {
        match classify_root(&path, RootShape::Root(kind)) {
            RootEntry::Usable => self.push_path(path),
            // Nothing at this path. It stays in `paths` — discovery skips what
            // is not there — and the kind reports a moved layout rather than
            // an empty inventory. A glob match that vanished between the
            // listing and this read, or one that is a dangling symlink,
            // lands here for the same reason and takes the same answer.
            RootEntry::Missing => {
                self.all_roots_present = false;
                self.push_path(path);
            }
            // Present and unreadable as a root of this kind. It contributes no
            // path and no evidence: the kind is unverifiable, never empty.
            RootEntry::Unusable(reason) => self.unusable.push(reason),
        }
    }

    /// The container a glob reads its matches out of. Not a root itself — it
    /// contributes no path — but judged by the same classifier, so a glob
    /// parent that is a regular file is unreadable rather than a glob that
    /// matched nothing. `false` when nothing may be read from it.
    fn admit_glob_parent(&mut self, parent: &Path) -> bool {
        match classify_root(parent, RootShape::GlobParent) {
            RootEntry::Usable => true,
            RootEntry::Missing => {
                self.all_roots_present = false;
                false
            }
            RootEntry::Unusable(reason) => {
                self.unusable.push(reason);
                false
            }
        }
    }

    fn push_path(&mut self, path: PathBuf) {
        if self
            .seen
            .insert(crate::config::normalize_path_lexical(&path))
        {
            self.paths.push(path);
        }
    }
}

pub(super) fn expand_configured_paths(
    source_root: &Path,
    kind: CatalogKind,
    catalog: &crate::mapping::CatalogConfig,
) -> Result<ExpandedRoots> {
    let mut out = ExpandedRoots::empty();
    for raw in catalog.paths_for(kind) {
        expand_catalog_entry(&mut out, source_root, &raw, kind)?;
    }
    Ok(out)
}

/// The forgiving path for the `discover_*` family, which is used by install
/// paths that must not fail over a mapping table. A root of the wrong type
/// contributes no paths here, exactly as it always has — discovery already
/// type-checks each candidate — and the report of it belongs to the callers
/// that classify removals.
pub(super) fn expand_paths_forgiving(
    source_root: &Path,
    kind: CatalogKind,
) -> Result<Vec<PathBuf>> {
    Ok(expand_configured_paths(
        source_root,
        kind,
        &crate::mapping::MappingConfig::load(source_root).catalog,
    )?
    .paths)
}

/// Expand one configured entry into `out`. Every root it produces is admitted
/// through [`ExpandedRoots::admit`]; the `Err` return is for a MALFORMED entry
/// alone, which is a configuration fault rather than a fact about the source.
pub(super) fn expand_catalog_entry(
    out: &mut ExpandedRoots,
    source_root: &Path,
    raw: &str,
    kind: CatalogKind,
) -> Result<()> {
    let trimmed = raw.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        anyhow::bail!("catalog path must not be empty");
    }

    let rel = Path::new(trimmed);
    if rel.is_absolute() {
        anyhow::bail!("catalog path must be relative to the source root: {trimmed}");
    }

    let mut parts: Vec<String> = Vec::new();
    for component in rel.components() {
        match component {
            Component::CurDir => {}
            Component::Normal(part) => parts.push(part.to_string_lossy().to_string()),
            Component::ParentDir | Component::Prefix(_) | Component::RootDir => {
                anyhow::bail!("catalog path must stay inside the source root: {trimmed}");
            }
        }
    }
    if parts.is_empty() {
        anyhow::bail!("catalog path must name a file or directory: {trimmed}");
    }
    if parts[..parts.len().saturating_sub(1)]
        .iter()
        .any(|part| part.contains('*'))
    {
        anyhow::bail!("catalog glob is only supported on the last path segment: {trimmed}");
    }

    let last = parts.last().expect("non-empty parts");
    if !last.contains('*') {
        out.admit(source_root.join(parts.iter().collect::<PathBuf>()), kind);
        return Ok(());
    }

    let parent_rel: PathBuf = parts[..parts.len() - 1].iter().collect();
    let parent = source_root.join(parent_rel);
    if !out.admit_glob_parent(&parent) {
        return Ok(());
    }
    let mut matches = Vec::new();
    for entry in std::fs::read_dir(&parent)
        .with_context(|| format!("reading catalog glob parent {}", parent.display()))?
    {
        let entry = entry?;
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if wildcard_match(last, name) {
            matches.push(path);
        }
    }
    // Sorted before admission so the roots, the reports and the inventory all
    // read in one order whatever the directory hands back.
    matches.sort();
    for path in matches {
        out.admit(path, kind);
    }
    Ok(())
}

/// Which configured path is being classified, and therefore what it is allowed
/// to be. A glob parent is always a container; a plain root is whatever its
/// kind reads items from.
#[derive(Clone, Copy)]
enum RootShape {
    Root(CatalogKind),
    GlobParent,
}

impl RootShape {
    /// The entry types this path may be, phrased for the report.
    fn requirement(self) -> String {
        match self {
            Self::Root(kind) => match kind.root_file_extension() {
                Some(ext) => format!("a directory or a .{ext} file"),
                None => "a directory".to_string(),
            },
            Self::GlobParent => "a directory".to_string(),
        }
    }

    fn accepts_file(self, path: &Path) -> bool {
        match self {
            Self::Root(kind) => kind
                .root_file_extension()
                .is_some_and(|ext| path.extension().is_some_and(|found| found == ext)),
            Self::GlobParent => false,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Root(_) => "catalog root",
            Self::GlobParent => "catalog glob parent",
        }
    }
}

/// What a configured path is, judged against what would be read from it.
enum RootEntry {
    Usable,
    /// Nothing at this path. Absence is a layout question, not a read failure.
    Missing,
    /// Present, but not a thing this kind can be read from — or not
    /// inspectable at all. Carries `path: what was found`.
    Unusable(String),
}

fn classify_root(path: &Path, shape: RootShape) -> RootEntry {
    // Follows symlinks deliberately: a symlinked root is a supported layout,
    // and what matters is what it resolves TO. A dangling link resolves to
    // nothing and is `NotFound`, i.e. missing, exactly like no entry at all.
    let meta = match std::fs::metadata(path) {
        Ok(meta) => meta,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return RootEntry::Missing,
        // Anything else — a permission bit on a parent, a symlink loop — means
        // the path was not measured. Reporting that as absent would classify
        // every item under it removed upstream.
        Err(err) => {
            return RootEntry::Unusable(format!(
                "{}: {} could not be inspected: {err}",
                path.display(),
                shape.label()
            ));
        }
    };
    if meta.is_dir() || (meta.is_file() && shape.accepts_file(path)) {
        return RootEntry::Usable;
    }
    let found = if meta.is_file() {
        "a regular file"
    } else {
        "neither a regular file nor a directory"
    };
    RootEntry::Unusable(format!(
        "{}: {} must be {}, found {found}",
        path.display(),
        shape.label(),
        shape.requirement()
    ))
}

pub(super) fn wildcard_match(pattern: &str, candidate: &str) -> bool {
    let pattern = pattern.as_bytes();
    let candidate = candidate.as_bytes();
    let mut pattern_index = 0;
    let mut candidate_index = 0;
    let mut star_index = None;
    let mut star_match_index = 0;

    while candidate_index < candidate.len() {
        if pattern_index < pattern.len()
            && pattern[pattern_index] != b'*'
            && pattern[pattern_index] == candidate[candidate_index]
        {
            pattern_index += 1;
            candidate_index += 1;
        } else if pattern_index < pattern.len() && pattern[pattern_index] == b'*' {
            star_index = Some(pattern_index);
            pattern_index += 1;
            star_match_index = candidate_index;
        } else if let Some(index) = star_index {
            pattern_index = index + 1;
            star_match_index += 1;
            candidate_index = star_match_index;
        } else {
            return false;
        }
    }

    while pattern_index < pattern.len() && pattern[pattern_index] == b'*' {
        pattern_index += 1;
    }

    pattern_index == pattern.len()
}
