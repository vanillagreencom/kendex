//! What the Community tab shows: the directory joined with what this
//! machine already subscribes to, and when the list was really fetched —
//! a row the person already has says "Subscribed", never a second
//! Subscribe button.

use crate::clock;
use crate::env::Env;
use crate::error::Result;
use crate::registry::index::{DirectoryBundle, DirectoryPackage};
use crate::registry::{Fetch, cache};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

#[derive(Debug, Clone, Serialize, Deserialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct DirectoryView {
    pub rows: Vec<DirectoryRow>,
    /// When the served list was actually fetched (ISO-8601) — the "as of"
    /// line when `stale` is true, the "updated" line otherwise.
    pub fetched_at: String,
    pub stale: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct DirectoryRow {
    pub repo: String,
    /// The canonical `owner/repo` a blind browse of this row fetches by, and
    /// what Subscribe is prefilled with.
    pub repo_key: Option<String>,
    /// One string per repository on any host, from
    /// [`crate::source_ref::repo_identity`] — what the live subscription
    /// list's own `repo_identity` is compared with, so the row flips to
    /// Subscribed however the subscription spells the repository.
    pub repo_identity: String,
    pub name: String,
    pub description: Option<String>,
    pub tags: Vec<String>,
    pub featured: bool,
    pub package_count: u32,
    pub bundle_count: u32,
    pub subscribed: bool,
    pub packages: Vec<DirectoryPackage>,
    pub bundles: Vec<DirectoryBundle>,
}

pub fn directory(env: &Env, fetch: &dyn Fetch, force_refresh: bool) -> Result<DirectoryView> {
    let subscribed = subscribed_repos(env)?;
    let loaded = cache::load(env, fetch, force_refresh)?;
    let rows = loaded
        .index
        .marketplaces
        .into_iter()
        .map(|market| {
            let name = market.name.clone().unwrap_or_else(|| leaf_of(&market.repo));
            let repo_identity = crate::source_ref::repo_identity(&market.repo);
            let is_subscribed = subscribed.contains(&repo_identity);
            DirectoryRow {
                repo_key: crate::source_ref::owner_repo(&market.repo),
                repo: market.repo,
                repo_identity,
                name,
                description: market.description,
                tags: market.tags,
                featured: market.featured,
                package_count: market.package_count,
                bundle_count: market.bundle_count,
                subscribed: is_subscribed,
                packages: market.packages,
                bundles: market.bundles,
            }
        })
        .collect();
    Ok(DirectoryView {
        rows,
        fetched_at: clock::iso_from_unix(loaded.fetched_at),
        stale: loaded.stale,
    })
}

/// Every repository any scope subscribes to, by identity.
fn subscribed_repos(env: &Env) -> Result<BTreeSet<String>> {
    Ok(crate::source_ops::repo_subscriptions(env)?
        .into_iter()
        .map(|row| row.repo_identity)
        .collect())
}

fn leaf_of(repo: &str) -> String {
    repo.rsplit('/').next().unwrap_or(repo).to_string()
}
