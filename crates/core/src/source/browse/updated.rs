//! When a catalog's content last moved: the commit the catalog is read at,
//! and the newest commit that touched each package it offers.
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
use std::path::PathBuf;

use crate::env::Env;
use crate::model::ItemKind;
use crate::remote::history;

use super::Browsed;

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

/// When the catalog was last updated: the committer date of the commit it
/// is being read at, ISO-8601.
pub(crate) fn catalog_date(env: &Env, browsed: &Browsed) -> Option<String> {
    let (mirror, commit) = mirror_at(env, browsed)?;
    history::commit_date(&mirror, &commit).ok().flatten()
}

/// When each named package last changed, ISO-8601, in one walk of the
/// history. A package the walk did not reach — history longer than the
/// bound, or a package whose files live outside the catalog's roots — has
/// no entry rather than a borrowed date.
pub(crate) fn package_dates(
    env: &Env,
    browsed: &Browsed,
    items: &[(ItemKind, String)],
) -> BTreeMap<(ItemKind, String), String> {
    let Some((mirror, commit)) = mirror_at(env, browsed) else {
        return BTreeMap::new();
    };
    // The checkout root is the repository root, so a package's path inside
    // the catalog is the path git knows it by.
    let root = browsed.sealed.root();
    let mut rel_for: Vec<((ItemKind, String), PathBuf)> = Vec::new();
    for (kind, name) in items {
        let Some(found) = super::super::find_item(&browsed.sealed, &browsed.config, *kind, name)
        else {
            continue;
        };
        let Ok(rel) = found.strip_prefix(root) else {
            continue;
        };
        rel_for.push(((*kind, name.clone()), rel.to_path_buf()));
    }
    let paths: Vec<PathBuf> = rel_for.iter().map(|(_, rel)| rel.clone()).collect();
    let Ok(dates) = history::last_changed(&mirror, &commit, &paths) else {
        return BTreeMap::new();
    };
    rel_for
        .into_iter()
        .filter_map(|(item, rel)| dates.get(&rel).map(|date| (item, date.clone())))
        .collect()
}
