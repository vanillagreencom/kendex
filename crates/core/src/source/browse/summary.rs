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
    /// What the catalog is, as its declaration spelled it: `owner/repo`
    /// only where it was written that way, a full URL where it was not, a
    /// path, or `local`. Opaque — `repo_key` below is the folded form.
    pub provenance: String,
    /// The canonical `owner/repo` the provenance folds to on GitHub — what
    /// a subscription's `repo_key` and a directory row are matched by,
    /// however the declaration spells it.
    pub repo_key: Option<String>,
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

/// One read of what the catalog says about itself. A bare repository that
/// no readable subscription holds is refreshed here — this is the page's
/// first read, so what follows reads the head it just fetched — and a
/// failed refresh serves the store with its warning rather than an empty
/// page.
pub fn summary(env: &Env, catalog: &Catalog) -> Result<CatalogSummary> {
    let (browsed, warning, subscription) = match catalog {
        Catalog::Subscription { scope, source } => (
            super::open(env, catalog)?,
            None,
            Some(SubscriptionRef {
                scope: scope.clone(),
                source: source.clone(),
            }),
        ),
        Catalog::Repo { repo } => {
            let key = super::browsable(repo)?;
            // A readable subscription already holds this repository: the
            // page carries on as it, from its own store and without the
            // network — a spelling that keys a different store entry must
            // not turn an offline open into a failed fetch.
            if let Some(held) = subscribed_as(env, &key)? {
                (open_held(env, &held)?, None, Some(held))
            } else {
                let resolution = crate::remote::sync(env, &key, None)?;
                let warning = resolution.warning.clone();
                // The fetch may be the one a never-fetched subscription
                // under this spelling was waiting for: it is Ready now, and
                // the page carries on as it rather than offering Subscribe.
                match subscribed_as(env, &key)? {
                    Some(held) => (open_held(env, &held)?, warning, Some(held)),
                    None => (super::open_repo(env, key, resolution)?, warning, None),
                }
            }
        }
    };
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
        repo_key: crate::source_ref::owner_repo(&browsed.source.provenance),
        provenance: browsed.source.provenance.clone(),
        commit: browsed.source.commit.clone(),
        meta: browsed.config.marketplace.clone(),
        mode: browsed.config.mode,
        counts,
        warning,
        subscription,
    })
}

/// A held subscription, opened from its own store.
fn open_held(env: &Env, held: &SubscriptionRef) -> Result<super::Browsed> {
    super::open(
        env,
        &Catalog::Subscription {
            scope: held.scope.clone(),
            source: held.source.clone(),
        },
    )
}

/// What the About tab reads: the catalog's own report, plus when its
/// content last moved. The date is git's, so a catalog kendex keeps no
/// history for has none — see [`super::updated`].
#[derive(Debug, Clone, PartialEq)]
pub struct CatalogAbout {
    pub report: AboutReport,
    /// ISO-8601 committer date of the newest commit that touched anything
    /// the catalog offers — never the commit it is read at, which moves for
    /// work on nothing it offers. Where the catalog offers a repository-root
    /// item, "anything it offers" is that item's whole tree: the repository
    /// bar the folders a root skill leaves out, so a build-output commit
    /// still moves nothing.
    pub updated_at: Option<String>,
}

/// The About report for any catalog: how its items were decided, what was
/// found where, everything wrong with it, and when it last changed.
pub fn about(env: &Env, catalog: &Catalog) -> Result<CatalogAbout> {
    let browsed = super::open(env, catalog)?;
    let offered = super::updated::offered(&browsed);
    Ok(CatalogAbout {
        report: crate::source::about(&browsed.sealed, &browsed.config),
        updated_at: super::updated::catalog_date(env, &browsed, &offered),
    })
}

/// The first subscription, personal scope first, that points at this
/// repository however it spells it and can be read right now. One that is
/// turned off or never fetched resolves as not Ready and is passed over:
/// the page just read the repository, and switching onto a subscription
/// whose content is unreachable would trade that for an empty page. A
/// manifest that cannot be read fails the summary instead of making its
/// subscription disappear.
fn subscribed_as(env: &Env, key: &str) -> Result<Option<SubscriptionRef>> {
    for row in crate::source_ops::repo_subscriptions(env)? {
        if row.repo_key.as_deref() != Some(key) {
            continue;
        }
        let Some(manifest) =
            crate::manifest::load_current(&crate::manifest::manifest_path(env, &row.scope))?
        else {
            continue;
        };
        if matches!(
            crate::source::resolve(env, &row.scope, &row.name, &manifest),
            Ok(crate::source::SourceState::Ready(_))
        ) {
            return Ok(Some(SubscriptionRef {
                scope: row.scope,
                source: row.name,
            }));
        }
    }
    Ok(None)
}
