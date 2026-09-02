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
/// as a catalog with no history at all. Set well clear of a mature
/// catalog: this repository's own skills tree has been touched by under
/// 200 first-parent commits in two years.
const MAX_DATED_COMMITS: usize = 5_000;

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

/// One walk of the mirror's history, answering for every offered item at
/// once.
struct Walked {
    changed: history::Changed,
    /// Each asked-about item with the path it was asked about under.
    asked: Vec<((ItemKind, String), PathBuf)>,
    /// Items that are the catalog root itself — see [`rel`].
    roots: Vec<(ItemKind, String)>,
    /// The repository's own tip date, read only when [`Walked::roots`] has
    /// something in it to spend it on.
    tip: Option<String>,
}

fn walk(env: &Env, browsed: &Browsed, items: &[Offered]) -> Option<Walked> {
    let (mirror, commit) = mirror_at(env, browsed)?;
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
    let paths: Vec<PathBuf> = asked.iter().map(|(_, path)| path.clone()).collect();
    let changed =
        history::last_changed(&mirror, &commit, &paths, MAX_DATED_COMMITS).unwrap_or_default();
    let tip = match roots.is_empty() {
        true => None,
        false => history::commit_date(&mirror, &commit).ok().flatten(),
    };
    Some(Walked {
        changed,
        asked,
        roots,
        tip,
    })
}

/// When each named package last changed, ISO-8601, in one walk of the
/// history. A package the walk did not reach — history longer than the
/// bound, or a package whose files live outside the catalog's roots — has
/// no entry rather than a borrowed date.
pub(crate) fn package_dates(
    env: &Env,
    browsed: &Browsed,
    items: &[Offered],
) -> BTreeMap<(ItemKind, String), String> {
    let Some(walked) = walk(env, browsed, items) else {
        return BTreeMap::new();
    };
    let mut out: BTreeMap<(ItemKind, String), String> = walked
        .asked
        .into_iter()
        .filter_map(|(item, path)| {
            walked
                .changed
                .dates
                .get(&path)
                .map(|date| (item, date.clone()))
        })
        .collect();
    if let Some(tip) = walked.tip {
        for item in walked.roots {
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
pub(crate) fn catalog_date(env: &Env, browsed: &Browsed, items: &[Offered]) -> Option<String> {
    let walked = walk(env, browsed, items)?;
    // A catalog that is itself one skill is the repository, so every commit
    // in it changed the catalog.
    match walked.roots.is_empty() {
        true => walked.changed.newest,
        false => walked.tip,
    }
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
