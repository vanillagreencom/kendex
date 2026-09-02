//! When a catalog's content last moved: when each package it offers last
//! changed, and the newest of those, which is the catalog's own date.
//!
//! Every offered item is dated over what it contains, so the two readings
//! cannot disagree — an item with a path is dated over that path, and one
//! that is the repository root over its whole tree. No item is dated by
//! the bare tip, which moves for commits inside no package at all.
//!
//! The dates come from the mirror's history, so only a catalog kendex
//! fetched from a repository has any. A path or `local` source is a
//! directory somebody keeps by hand, and a date invented from a file's
//! mtime would say when this machine last wrote it rather than when the
//! package changed.
//!
//! A history that will not read costs the dates and nothing else — a
//! column with no date in it says nothing, where a page that refused to
//! draw would lose the packages too.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::model::ItemKind;
use crate::remote::history;

use super::Browsed;

/// This module's own bound on the history walk, counted in commits that
/// touched one of the catalog's packages — `--max-count` applies after the
/// pathspec filter, so unrelated work in the same repository does not spend
/// it. A package whose newest commit lies past it shows no date, the same
/// as a catalog with no history at all.
///
/// Chosen against the byte cap rather than against a catalog's age, so the
/// two bounds cannot contradict each other. [`history`]'s cap refuses a
/// read over 1 MB outright — every package losing its date at once, the
/// opposite of the per-package degradation this bound exists to give — so
/// the commit bound has to be the one that fires.
///
/// The density that decides where it fires is the catalog's, and it turns
/// on how many pathspecs [`offered`] resolves, which turns on the
/// catalog's mode and declared kinds — so a bare figure here is not
/// reproducible from the sentence holding it. The command that produces
/// one, over whatever set that catalog really uses:
///
/// ```text
/// git --git-dir <mirror> log --first-parent --max-count 1000 \
///     --name-only -z --format=%x00%cI <tip> -- <one :(literal) per item>
/// ```
///
/// Over kendex's own mirror that is 601 B per matching commit across the
/// 43 specs an Explicit catalog resolves there (20 skills, 16 agents, 7
/// hooks), putting 1 MB past 1,600 commits; independent derivations
/// counting different kinds have run to 790 B, which still puts it past
/// 1,200. The bound fits under the cap at all of them, and 5,000 could not
/// be reached at any: the cap would always fire first.
///
/// Density is the catalog's to choose, so one changing enough files per
/// commit can still cross the cap and blank the column. The Packages table
/// is the only surface left in that blast radius: [`catalog_date`] asks a
/// question whose answer is one record.
const MAX_DATED_COMMITS: usize = 1_000;

/// What a repository-root skill's tree leaves out, as pathspecs.
///
/// Derived from [`crate::source_read::NOT_CONTENT`], never restated: a
/// root skill IS the repository, so everything but those folders is
/// content the skill publishes and an install copies — `crates/`, `ui/`
/// and `docs/` included. Asking history for that set is the only way to
/// date such an item honestly; the bare tip would count a `target/`-only
/// commit, which changed nothing the skill contains. A folder added to
/// the one list is added here by construction.
fn root_tree_specs() -> Vec<String> {
    crate::source_read::NOT_CONTENT
        .iter()
        .map(|folder| history::excluding(folder))
        .collect()
}

/// One item the catalog offers, with where its bytes are.
pub(crate) struct Offered {
    pub(crate) kind: ItemKind,
    pub(crate) name: String,
    /// Absolute, as [`super::super::find_item`] answers. `None` for a name
    /// the catalog lists but no longer carries.
    pub(crate) found: Option<PathBuf>,
}

/// Every item the catalog offers, each resolved exactly once.
///
/// `find_item` is a filesystem walk, not a lookup — `SealedSource` checks
/// every path component below the root for a symlink — so the callers that
/// need both a package's header and its date resolve here and share the
/// answer.
pub(crate) fn offered(browsed: &Browsed) -> Vec<Offered> {
    let mut out = Vec::new();
    for kind in ItemKind::ALL {
        for name in super::super::list_items(&browsed.sealed, &browsed.config, kind) {
            let found = super::super::find_item(&browsed.sealed, &browsed.config, kind, &name);
            out.push(Offered { kind, name, found });
        }
    }
    out
}

/// The mirror a browsed catalog's history lives in, with the commit being
/// read. `None` where there is no history to read: a path or `local`
/// source carries no commit, and a mirror cleaned away since the checkout
/// was published leaves the checkout readable but its history gone.
fn mirror_at(env: &Env, browsed: &Browsed) -> Option<(PathBuf, String)> {
    let commit = browsed.source.commit.clone()?;
    let key = crate::remote::cache_key(env, &browsed.source.provenance);
    let mirror = crate::remote::store::mirror_dir(env, &key);
    mirror.is_dir().then_some((mirror, commit))
}

/// The path git knows an item by, relative to the catalog root.
///
/// `None` where the item IS the catalog root — a repository that is itself
/// one skill. Stripping leaves the empty path, and an empty pathspec is not
/// an error but a match on every path in the repository: it would date that
/// skill from any commit at all, and, sharing a walk with the other
/// packages' pathspecs, would spend the walk's newest commits on itself.
/// Such an item is dated over its own tree instead — the repository minus
/// the folders a root skill leaves out — which [`root_tree_specs`] asks for
/// as a pathspec set. Not the bare tip either: a commit under one of those
/// folders changed nothing the skill publishes, so it dates nothing.
fn rel(root: &Path, found: &Path) -> Option<PathBuf> {
    let rel = found.strip_prefix(root).ok()?;
    (!rel.as_os_str().is_empty()).then(|| rel.to_path_buf())
}

/// The offered items sorted into the ones the history can be asked about
/// and the ones that are the catalog root itself — see [`rel`].
type Split = (Vec<((ItemKind, String), PathBuf)>, Vec<(ItemKind, String)>);

fn split(browsed: &Browsed, items: &[Offered]) -> Split {
    // The checkout root is the repository root, so a package's path inside
    // the catalog is the path git knows it by.
    let root = browsed.sealed.root();
    let mut asked = Vec::new();
    let mut roots = Vec::new();
    for item in items {
        let key = (item.kind, item.name.clone());
        match item.found.as_deref().map(|found| rel(root, found)) {
            Some(Some(path)) => asked.push((key, path)),
            Some(None) => roots.push(key),
            None => {}
        }
    }
    (asked, roots)
}

/// When each named package last changed, ISO-8601, in one walk of the
/// history. A package the walk did not reach — history longer than the
/// bound, or a package whose files live outside the catalog's roots — has
/// no entry rather than a borrowed date.
///
/// An item that IS the catalog root is dated over its own tree — the
/// repository minus [`crate::source_read::NOT_CONTENT`] — in a mixed
/// catalog as much as in
/// a one-skill one, because that tree is what the item contains:
/// `package_preview` lists a root skill's files from the root down, so a
/// commit anywhere but those folders really did change it. Not the bare
/// tip, which would date it from a `target/`-only commit that changed
/// nothing it publishes.
pub(crate) fn package_dates(
    env: &Env,
    browsed: &Browsed,
    items: &[Offered],
) -> BTreeMap<(ItemKind, String), String> {
    let Some((mirror, commit)) = mirror_at(env, browsed) else {
        return BTreeMap::new();
    };
    let (asked, roots) = split(browsed, items);
    let paths: Vec<PathBuf> = asked.iter().map(|(_, path)| path.clone()).collect();
    let changed =
        history::last_changed(&mirror, &commit, &paths, MAX_DATED_COMMITS).unwrap_or_default();
    let mut out: BTreeMap<(ItemKind, String), String> = asked
        .into_iter()
        .filter_map(|(item, path)| changed.dates.get(&path).map(|date| (item, date.clone())))
        .collect();
    if !roots.is_empty()
        && let Some(date) = history::newest_touching(&mirror, &commit, &root_tree_specs())
            .ok()
            .flatten()
    {
        for item in roots {
            out.insert(item, date.clone());
        }
    }
    out
}

/// When the catalog was last updated: the newest commit that touched
/// anything it offers.
///
/// Not the repository's tip. A repository can be a catalog and a codebase
/// at once — kendex's own is, with `skills/` and `agents/` beside
/// `crates/` and `ui/` — and a commit that touched only the codebase moves
/// the tip without changing a single thing the marketplace offers. Not the
/// tip even where the catalog IS the whole repository: a root item is
/// asked about over its own tree, so a commit under one of the folders a
/// root skill leaves out still moves nothing.
///
/// Asked as its own one-record query rather than taken from the dating
/// walk. The walk lists every filename in every matching commit to answer
/// for each package separately; this wants one date, and asking for it
/// directly is the difference between 134 kB and 21 bytes on a real
/// mirror. It also keeps the About tab clear of the byte cap that bounds
/// the walk.
///
/// Every offered item counts, with no special case for the root one. An
/// item that IS the catalog root has no narrower path, but it does have a
/// tree — the repository minus [`crate::source_read::NOT_CONTENT`] — and that tree
/// subsumes the other packages' paths, so where such an item is offered
/// one query over it answers for the whole catalog. The About tab can
/// therefore never read older than a package on the Packages tab beside
/// it, and a commit that adds a root skill moves the date, because it
/// added something the marketplace offers.
pub(crate) fn catalog_date(env: &Env, browsed: &Browsed, items: &[Offered]) -> Option<String> {
    let (mirror, commit) = mirror_at(env, browsed)?;
    let (asked, roots) = split(browsed, items);
    let specs = match roots.is_empty() {
        true => asked
            .iter()
            .map(|(_, path)| history::literal(path))
            .collect(),
        false => root_tree_specs(),
    };
    history::newest_touching(&mirror, &commit, &specs)
        .ok()
        .flatten()
}

#[cfg(test)]
mod tests {
    use super::rel;
    use std::path::{Path, PathBuf};

    #[test]
    fn an_item_that_is_the_catalog_root_yields_no_pathspec() {
        let root = Path::new("/store/commits/abc");
        assert_eq!(
            rel(root, Path::new("/store/commits/abc/skills/gh")),
            Some(PathBuf::from("skills/gh"))
        );
        // The empty pathspec git would build from this matches every path
        // in the repository, so the walk is never asked for it.
        assert_eq!(rel(root, root), None);
        assert_eq!(rel(root, Path::new("/elsewhere")), None);
    }
}
