//! A catalog's own account of itself — what the marketplace page's header
//! and About tab show, for a subscription or a repository browsed before
//! subscribing.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::env::Env;
use crate::error::Result;
use crate::model::{ItemKind, Scope};
use crate::source::{AboutReport, CatalogMode, MarketplaceMeta};

use super::Catalog;

/// The subscription a browsed repository already has on this machine, so
/// the page can carry on as that subscription instead of a stranger.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SubscriptionRef {
    pub scope: Scope,
    pub source: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct CatalogSummary {
    /// `owner/repo`, a path, or `local` — what the catalog is.
    pub provenance: String,
    /// The commit being read, for a remote.
    pub commit: Option<String>,
    /// `[marketplace]` from the catalog's own kendex.toml.
    pub meta: Option<MarketplaceMeta>,
    pub mode: CatalogMode,
    /// Packages offered, by kind name.
    pub counts: BTreeMap<String, u32>,
    /// Set when the catalog is read from the store because a refresh failed.
    pub warning: Option<String>,
    /// For a repository: the subscription this machine already holds for
    /// it, if any. A subscription answers with itself.
    pub subscription: Option<SubscriptionRef>,
}

/// One read of what the catalog says about itself. A bare repository is
/// refreshed here — this is the page's first read, so what follows reads
/// the head it just fetched — and a failed refresh serves the store with
/// its warning rather than an empty page.
pub fn summary(env: &Env, catalog: &Catalog) -> Result<CatalogSummary> {
    let (warning, subscription) = match catalog {
        Catalog::Subscription { scope, source } => (
            None,
            Some(SubscriptionRef {
                scope: scope.clone(),
                source: source.clone(),
            }),
        ),
        Catalog::Repo { repo } => {
            let warning = match crate::repo_move::owner_repo(repo) {
                Some(_) => crate::remote::sync(env, repo.trim(), None)?.warning,
                // open() below names the refusal.
                None => None,
            };
            (warning, subscribed_as(env, repo))
        }
    };
    let browsed = super::open(env, catalog)?;
    let mut counts = BTreeMap::new();
    for kind in ItemKind::ALL {
        let offered = crate::source::list_items(&browsed.sealed, &browsed.config, kind).len();
        if offered > 0 {
            counts.insert(
                kind.name().to_owned(),
                offered.min(u32::MAX as usize) as u32,
            );
        }
    }
    Ok(CatalogSummary {
        provenance: browsed.source.provenance.clone(),
        commit: browsed.source.commit.clone(),
        meta: browsed.config.marketplace.clone(),
        mode: browsed.config.mode,
        counts,
        warning,
        subscription,
    })
}

/// The About report for any catalog: how its items were decided, what was
/// found where, and everything wrong with it.
pub fn about(env: &Env, catalog: &Catalog) -> Result<AboutReport> {
    let browsed = super::open(env, catalog)?;
    Ok(crate::source::about(&browsed.sealed, &browsed.config))
}

/// The first subscription, personal scope first, that points at this
/// repository however it spells it. A scope that cannot be read holds no
/// subscription rather than blocking the page.
fn subscribed_as(env: &Env, repo: &str) -> Option<SubscriptionRef> {
    let key = crate::repo_move::owner_repo(repo)?;
    let mut scopes = vec![Scope::Global];
    if let Ok(settings) = crate::settings::load(env) {
        scopes.extend(
            settings
                .projects
                .into_iter()
                .map(|root| Scope::Project { root }),
        );
    }
    scopes.into_iter().find_map(|scope| {
        let rows = crate::source_ops::list_subscriptions(env, &scope).ok()?;
        rows.into_iter()
            .find(|row| {
                row.repo
                    .as_deref()
                    .and_then(crate::repo_move::owner_repo)
                    .is_some_and(|candidate| candidate == key)
            })
            .map(|row| SubscriptionRef {
                scope,
                source: row.name,
            })
    })
}
