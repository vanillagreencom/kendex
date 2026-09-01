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
    /// The canonical key a subscription's `repo_key` is compared with, so
    /// the row can flip to Subscribed from the live subscription list.
    pub repo_key: Option<String>,
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
            let repo_key = crate::source_ref::owner_repo(&market.repo);
            let is_subscribed = repo_key
                .as_ref()
                .is_some_and(|key| subscribed.contains(key));
            DirectoryRow {
                repo: market.repo,
                repo_key,
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

/// Every repository any scope subscribes to, spelled the one canonical
/// way.
fn subscribed_repos(env: &Env) -> Result<BTreeSet<String>> {
    Ok(crate::source_ops::repo_subscriptions(env)?
        .into_iter()
        .filter_map(|row| row.repo_key)
        .collect())
}

fn leaf_of(repo: &str) -> String {
    repo.rsplit('/').next().unwrap_or(repo).to_string()
}
