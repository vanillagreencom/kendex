//! What a saved item is right now: which catalog on this machine carries
//! its marketplace, and whether that marketplace still offers it.
//!
//! Nothing here is stored. A bookmark records an identity, and this is the
//! read that turns one back into something a surface can open, install or
//! explain — asked of the ordinary browse reader, so what the Bookmarks
//! list says a marketplace offers and what its own page says cannot
//! disagree.
//!
//! No read here reaches the network. A marketplace nothing on this machine
//! subscribes to answers [`Reach::Unsubscribed`] without being fetched:
//! opening its page is what fetches it, and a list of saved items must not
//! become one network round trip per row.

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::env::Env;
use crate::error::Result;
use crate::source::browse::{self, Catalog};

use super::{Bookmark, BookmarkItem};

/// Where a saved item stands on this machine.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(
    tag = "at",
    rename_all = "kebab-case",
    rename_all_fields = "kebab-case"
)]
pub enum Reach {
    /// A subscription here carries the marketplace, its catalog reads, and
    /// it still offers this item. The one state an install may start from.
    Offered,
    /// The catalog reads and no longer offers it — renamed or dropped
    /// after the bookmark was saved. The row stays, saying so.
    NotOffered { why: String },
    /// Nothing here subscribes to the marketplace, and it is a repository
    /// kendex can browse. Opening the row fetches it; installing from it
    /// subscribes first, which is the marketplace page's own offer and not
    /// this list's to make.
    Unsubscribed,
    /// The marketplace cannot be served right now, or cannot be addressed
    /// at all. `why` is the whole reason, from whichever reader judged it.
    Unavailable { why: String },
}

/// One saved item as a surface draws it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SavedItem {
    pub bookmark: Bookmark,
    /// The marketplace folded to one string, from
    /// [`crate::source_ref::repo_identity`]. Carried rather than left to
    /// the reader: a surface deciding whether the row it is drawing is
    /// saved compares this against its own marketplace's identity, and a
    /// second spelling of that fold outside core is a second answer.
    pub repo_identity: String,
    /// The catalog this item is addressed through, or null where nothing
    /// on this machine can address the marketplace at all. It is what a
    /// row opens; a row with none opens nothing rather than opening some
    /// other marketplace's page.
    pub catalog: Option<Catalog>,
    pub reach: Reach,
}

/// Every saved item, read against this machine.
pub fn resolve(env: &Env) -> Result<Vec<SavedItem>> {
    let subscriptions = crate::source_ops::subscriptions(env)?;
    super::list(env)?
        .into_iter()
        .map(|bookmark| one(env, &subscriptions, bookmark))
        .collect()
}

fn one(
    env: &Env,
    subscriptions: &[crate::source_ops::Subscription],
    bookmark: Bookmark,
) -> Result<SavedItem> {
    let repo_identity = crate::source_ref::repo_identity(&bookmark.repo);
    let (catalog, reach) = stands(env, subscriptions, &repo_identity, &bookmark);
    Ok(SavedItem {
        bookmark,
        repo_identity,
        catalog,
        reach,
    })
}

/// Which catalog carries this bookmark's marketplace, and what that
/// catalog says about the item.
///
/// Every subscription declaring the marketplace is tried, personal scope
/// first, and the first one that opens answers — the rule
/// `browse::summary` already keeps for a blind browse that finds a
/// subscription. A marketplace declared in two places where the first
/// declaration is switched off or never fetched is still reachable through
/// the second, and only when none of them opens does the first refusal
/// stand as the reason.
fn stands(
    env: &Env,
    subscriptions: &[crate::source_ops::Subscription],
    repo_identity: &str,
    bookmark: &Bookmark,
) -> (Option<Catalog>, Reach) {
    let mut refused: Option<(Catalog, String)> = None;
    for row in subscriptions
        .iter()
        .filter(|row| row.repo_identity == repo_identity)
    {
        let catalog = Catalog::Subscription {
            scope: row.scope.clone(),
            source: row.name.clone(),
        };
        match offers(env, &catalog, bookmark.item, &bookmark.name) {
            Ok(true) => return (Some(catalog), Reach::Offered),
            Ok(false) => {
                return (
                    Some(catalog),
                    Reach::NotOffered {
                        why: no_longer_offered(bookmark),
                    },
                );
            }
            Err(error) => refused.get_or_insert((catalog, error.to_string())),
        };
    }
    if let Some((catalog, why)) = refused {
        return (Some(catalog), Reach::Unavailable { why });
    }
    // Nothing declares it. A GitHub repository is still addressable — the
    // marketplace page opens one nobody subscribes to — and anything else
    // is a folder or a host kendex is given no way to reach without a
    // declaration to read it from.
    match crate::source_ref::owner_repo(&bookmark.repo) {
        Some(key) => (Some(Catalog::Repo { repo: key }), Reach::Unsubscribed),
        None => (
            None,
            Reach::Unavailable {
                why: unaddressable(&bookmark.repo),
            },
        ),
    }
}

fn offers(env: &Env, catalog: &Catalog, item: BookmarkItem, name: &str) -> Result<bool> {
    match item.kind() {
        Some(kind) => browse::offers_package(env, catalog, kind, name),
        None => browse::offers_bundle(env, catalog, name),
    }
}

fn no_longer_offered(bookmark: &Bookmark) -> String {
    format!(
        "{} no longer offers this {} — it was renamed or dropped after you saved it",
        crate::names::shown(&bookmark.repo),
        bookmark.item.name()
    )
}

fn unaddressable(repo: &str) -> String {
    format!(
        "nothing on this machine subscribes to {}, and it is not a repository kendex can browse without one — subscribe to it, then open this again",
        crate::names::shown(repo)
    )
}
