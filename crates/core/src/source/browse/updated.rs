//! When a catalog's content last moved: when each package it offers last
//! changed, and the newest of those, which is the catalog's own date.
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
/// two bounds cannot contradict each other. `--name-only` output runs
/// around 600 to 750 bytes per matching commit for a catalog of a few
/// dozen packages — 621 B/commit measured over kendex's own mirror, which
/// puts 1 MB at about 1,600 commits — and [`history`]'s cap refuses a read
/// over 1 MB outright, every package losing its date at once, which is the
/// opposite of the per-package degradation this bound exists to give. At
/// 1,000 the walk fits with room at that density. A bound of 5,000 could
/// never be reached: the cap would always fire first.
///
/// Density is the catalog's to choose, so one changing enough files per
/// commit can still cross the cap and blank the column. The Packages table
/// is the only surface left in that blast radius: [`catalog_date`] asks a
/// question whose answer is one record.
const MAX_DATED_COMMITS: usize = 1_000;

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
/// Such an item is dated from the repository's own tip instead, which for a
/// catalog that is one skill is the same fact.
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
/// An item that IS the catalog root takes the repository's tip, in a mixed
/// catalog as much as in a one-skill one, because its own tree is the
/// repository: `package_preview` lists a root skill's files from the root
/// down, so a commit anywhere but the excluded build and vendor folders
/// really did change it. That is this item's honest date and no borrowing
/// — [`catalog_date`] is where the tip must not speak for packages that
/// have paths of their own.
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
        && let Some(tip) = history::commit_date(&mirror, &commit).ok().flatten()
    {
        for item in roots {
            out.insert(item, tip.clone());
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
/// the tip without changing a single thing the marketplace offers. Where
/// the catalog is the whole repository the two are the same date anyway.
///
/// Asked as its own one-record query rather than taken from the dating
/// walk. The walk lists every filename in every matching commit to answer
/// for each package separately; this wants one date, and asking for it
/// directly is the difference between 134 kB and 21 bytes on a real
/// mirror. It also keeps the About tab clear of the byte cap that bounds
/// the walk.
///
/// An item that IS the catalog root makes the repository's tip a candidate,
/// never an override. The tip wins only where that item is the whole offer:
/// then the repository is the catalog, and every commit in it changed the
/// catalog. A repository carrying a root `SKILL.md` beside `skills/` offers
/// both — `discover` adds the root skill whenever the file is there, with
/// no guard requiring the rest of the discovery to be empty — and there the
/// packages have paths of their own, so a commit that touched none of them
/// did not change what the marketplace offers, whatever else it touched.
pub(crate) fn catalog_date(env: &Env, browsed: &Browsed, items: &[Offered]) -> Option<String> {
    let (mirror, commit) = mirror_at(env, browsed)?;
    let (asked, roots) = split(browsed, items);
    if asked.is_empty() {
        return match roots.is_empty() {
            true => None,
            false => history::commit_date(&mirror, &commit).ok().flatten(),
        };
    }
    let paths: Vec<PathBuf> = asked.into_iter().map(|(_, path)| path).collect();
    history::newest_touching(&mirror, &commit, &paths)
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
